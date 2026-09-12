-- 符号/引用树展示与交互，复用 tree_panel 和 prompt；不发起 LSP 请求
local Tree = require('vv-utils.tree_panel')
local Prompt = require('vv-utils.prompt')
local Match = require('vv-utils.match')
local Model = require('vv-symbols.model')
local Renderer = require('vv-symbols.render')
local Preview = require('vv-symbols.preview')
local Navigation = require('vv-symbols.navigation')
local M = {}
local View = {}
View.__index = View

local function clean(text) return tostring(text or ''):gsub('[\r\n\t]', ' ') end

local function action_available(view, action)
  if action == 'back' then return view.reference_mode and view.return_to_symbols ~= nil end
  if action == 'references' or action == 'functions' then return not view.reference_mode end
  if action == 'kind' then return not view.reference_mode or view.data.mode == 'diagnostics' end
  return true
end

local function action_label(view, action)
  if action == 'back' then return 'back to symbols' end
  if action == 'kind' and view.data.mode == 'diagnostics' then return 'severity' end
  return action
end

local function hints(view)
  local found = {}
  for lhs, action in pairs(view.opts.config.keymaps) do
    if
      action
      and action_available(view, action)
      and (not found[action] or #lhs < #found[action] or (#lhs == #found[action] and lhs < found[action]))
    then
      found[action] = lhs
    end
  end
  local result = {}
  for _, item in ipairs({
    { 'filter', 'filter' },
    { 'kind', 'kind' },
    { 'functions', 'functions' },
    { 'references', 'references' },
    { 'back', 'back' },
    { 'help', 'help' },
  }) do
    if found[item[1]] then result[#result + 1] = { key = found[item[1]], label = action_label(view, item[1]) } end
  end
  return result
end

--- Keep actual mappings, toolbar hints and generated help in the same context.
local function sync_actions(view)
  if not view.actions or not view.tree.buf or not vim.api.nvim_buf_is_valid(view.tree.buf) then return end
  for lhs, action in pairs(view.opts.config.keymaps) do
    if action then
      if action_available(view, action) then
        local callback = view.actions[action] or function() view.tree:execute(action) end
        vim.keymap.set('n', lhs, callback, {
          buffer = view.tree.buf,
          silent = true,
          nowait = true,
          desc = 'vv-symbols: ' .. action_label(view, action),
        })
      else
        pcall(vim.keymap.del, 'n', lhs, { buffer = view.tree.buf })
      end
    end
  end
end

local function selected(view)
  local tree = view.tree
  if not tree:is_open() then return end
  local row = tree.rows[vim.api.nvim_win_get_cursor(tree.win)[1]]
  return row and row.node
end

local function source_window(view)
  local tree = view.tree
  if view.preview and vim.api.nvim_win_is_valid(view.preview.source_win) then return view.preview.source_win end
  -- 优先使用新文档实际所在窗口，不继续写入最初打开面板的窗口
  local current = vim.api.nvim_get_current_win()
  if
    view.data.buf
    and vim.api.nvim_win_get_buf(current) == view.data.buf
    and vim.bo[view.data.buf].buftype == ''
    and vim.api.nvim_win_get_config(current).relative == ''
  then
    tree.source_win = current
    return current
  end
  for _, candidate in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if
      view.data.buf
      and vim.api.nvim_win_get_buf(candidate) == view.data.buf
      and vim.bo[view.data.buf].buftype == ''
      and vim.api.nvim_win_get_config(candidate).relative == ''
    then
      tree.source_win = candidate
      return candidate
    end
  end
  local win = tree.source_win
  if win and vim.api.nvim_win_is_valid(win) and vim.bo[vim.api.nvim_win_get_buf(win)].buftype == '' then return win end
  for _, candidate in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if
      vim.api.nvim_win_get_config(candidate).relative == ''
      and vim.bo[vim.api.nvim_win_get_buf(candidate)].buftype == ''
    then
      tree.source_win = candidate
      return candidate
    end
  end
end

local function restore_preview(view, focus)
  local active = view.preview
  view.preview = nil
  if active then
    active:restore({ focus = focus })
  elseif
    focus
    and view.tree.source_win
    and vim.api.nvim_win_is_valid(view.tree.source_win)
    and vim.api.nvim_win_get_tabpage(view.tree.source_win) == vim.api.nvim_get_current_tabpage()
  then
    vim.api.nvim_set_current_win(view.tree.source_win)
  end
end

local function jump(view, node)
  if not node or not node.uri or not node.selection_range then return end
  local win = source_window(view)
  if not win then return end
  local active = view.preview or Preview.new(win)
  if active:commit(node) then view.preview = nil end
end

local function preview(view, node)
  if not view.opts.config.panel.preview or not node or not node.selection_range then return end
  -- Enter 已转入源码时，丢弃侧栏之前排队的 CursorMoved 预览
  if vim.api.nvim_get_current_win() ~= view.tree.win and not view.prompt then return end
  local win = source_window(view)
  if not win then return end
  view.preview = view.preview or Preview.new(win)
  view.preview:show(node)
end

local function apply_filter(view)
  local result =
    Model.filter({ nodes = view.data.nodes or {}, query = view.query, mode = view.mode, kinds = view.kinds })
  view.valid = result.valid
  if result.valid then
    view.filtered, view.count, view.total = result.nodes, result.count, result.total
  end
  -- 筛选期间展开上下文，离开筛选后恢复用户原来的折叠状态
  local filtering = view.query ~= '' or view.kinds ~= nil
  if filtering and not view.saved_folds then
    view.saved_folds = vim.deepcopy(view.tree.folded)
  elseif not filtering and view.saved_folds then
    view.tree.folded, view.saved_folds = view.saved_folds, nil
  end
  if filtering then view.tree.folded = {} end
  sync_actions(view)
  view.tree:refresh()
  if view.prompt then view.prompt.redraw() end
end

---创建面板实例；回调由 owning 控制器注入
---@param opts {config:VVSymbolsConfig,on_refresh:fun(),on_close:fun(),on_references:fun(node:table)}
---@return VVSymbolsView
function M.new(opts)
  local view = setmetatable({
    opts = opts,
    query = '',
    mode = opts.config.filter.mode,
    kinds = opts.config.filter.kinds or nil,
    valid = true,
    count = 0,
    total = 0,
    data = { nodes = {}, results = {}, status = 'loading' },
    filtered = {},
  }, View)
  view.tree = Tree.new({
    id = 'vv-symbols',
    filetype = 'vv-symbols',
    title = 'Symbols',
    width = opts.config.panel.width,
    position = opts.config.panel.position,
    state = opts.config.panel.state or nil,
    toolbar = { position = 'bottom', items = function() return hints(view) end, key_hl = 'Special' },
    source = function() return view.filtered end,
    preview = function(node) preview(view, node) end,
    open = function(node) jump(view, node) end,
    jump = function(node) jump(view, node) end,
    on_refresh = opts.on_refresh,
    on_close = function()
      if view.resize_group then
        vim.api.nvim_del_augroup_by_id(view.resize_group)
        view.resize_group = nil
      end
      view:close_prompt()
      restore_preview(view, true)
      view.reference_mode = false
      view.return_to_symbols, view.pending_return = nil, nil
      opts.on_close()
    end,
    on_attach = function(tree, buf)
      -- 窗口打开时设一次；数据刷新不写回尺寸，也不抢占缩放键
      require('vv-utils.mouse').block_visual_drag(buf)
      view.resize_group = vim.api.nvim_create_augroup('VVSymbolsResize' .. buf, { clear = true })
      view.render_width = tree:get_width()
      vim.api.nvim_create_autocmd('WinResized', {
        group = view.resize_group,
        callback = function()
          if tree:is_open() and tree:get_width() ~= view.render_width then
            view.render_width = tree:get_width()
            tree:render()
          end
        end,
      })
      local actions = {
        next_item = function() Navigation.move(tree, 1) end,
        prev_item = function() Navigation.move(tree, -1) end,
        open_node = function() Navigation.open(tree) end,
        filter = function() view:filter() end,
        kind = function() view:choose_kind() end,
        functions = function()
          local kinds = not vim.deep_equal(view.kinds, { 'Function' }) and { 'Function' } or false
          view:set_filter({ kinds = kinds })
        end,
        clear_filter = function() view:set_filter({ query = '', kinds = false }) end,
        references = function()
          local node = selected(view)
          if node and not view.reference_mode and not node.context_only then
            view.pending_return = {
              buf = view.data.buf,
              filter = { query = view.query, mode = view.mode, kinds = vim.deepcopy(view.kinds or false) },
              folded = vim.deepcopy(view.tree.folded),
              saved_folds = vim.deepcopy(view.saved_folds),
              selected_id = node.id,
            }
            opts.on_references(node)
            view.pending_return = nil
          end
        end,
        back = function() view:back() end,
        refresh = opts.on_refresh,
        close = function() view:close() end,
        open = function() jump(view, selected(view)) end,
        help = function()
          require('vv-utils.help_panel').open({
            source_buf = buf,
            desc_prefix = 'vv-symbols: ',
            title = 'Symbols',
            extra_rows = {
              { lhs = '<S-Tab>', action = 'cycle filter mode', cat = 'Filter input' },
              { lhs = '<C-n>/<C-p>', action = 'navigate matches', cat = 'Filter input' },
              { lhs = '<CR>', action = 'accept filter', cat = 'Filter input' },
              { lhs = '<Esc>', action = 'restore previous filter', cat = 'Filter input' },
            },
          })
        end,
      }
      view.actions = actions
      sync_actions(view)
    end,
    render = {
      winbar = function()
        local kind = view.kinds and table.concat(view.kinds, ', ') or 'All'
        return {
          text = (view.data.title or 'Symbols') .. ' · ' .. kind .. (' · %d/%d'):format(view.count, view.total),
          hl = 'Title',
        }
      end,
      header = function()
        local query = view.query ~= '' and (' · ' .. view.mode .. ': ' .. clean(view.query)) or ''
        local name = Renderer.source_path({
          buf = view.data.buf,
          width = view.tree and (view.tree:get_width() - vim.fn.strdisplaywidth(query) - 1),
        })
        return { text = name .. query, hl = 'Comment' }
      end,
      node = function(ctx)
        ctx.result = view.data.results and view.data.results[ctx.node.id]
        return Renderer.node(ctx)
      end,
      empty = function()
        local text = view.data.status == 'loading' and 'Loading…' or view.data.error or 'No matching items'
        return { text = clean(text), hl = view.data.error and 'DiagnosticWarn' or 'Comment' }
      end,
      footer = function()
        if not view.valid then return { text = 'Invalid regular expression', hl = 'DiagnosticError' } end
      end,
    },
  })
  return view
end

---更新快照；引用计数更新不打断详情，失效/loading 则撤销旧引用位置
---@param data table
function View:update(data)
  if self.reference_mode and self.data.buf == data.buf and data.status == 'ready' then
    self.back_data = data
    return
  end
  if self.data.buf ~= data.buf or data.status ~= 'ready' then
    restore_preview(self)
    self.reference_mode = false
    self.back_data = nil
  end
  self.data = data
  source_window(self)
  apply_filter(self)
end

---打开并聚焦面板
function View:open()
  if not self.tree:is_open() and self.opts.config.panel.preview then
    local win = source_window(self)
    if win then self.preview = Preview.new(win) end
  end
  self.tree:open()
  if self.reference_mode then Navigation.focus_result(self.tree) end
end
---幂等关闭输入和面板
function View:close()
  self:close_prompt()
  if self.tree:is_open() and #vim.api.nvim_list_tabpages() == 1 then
    local normal = vim.tbl_filter(
      function(win) return win ~= self.tree.toolbar_win and vim.api.nvim_win_get_config(win).relative == '' end,
      vim.api.nvim_tabpage_list_wins(0)
    )
    if #normal == 1 and normal[1] == self.tree.win then
      -- 源码窗口被关闭后，面板可能成为最后窗口；替换 buffer 让 wipe 负责清理
      local win = self.tree.win
      require('vv-utils.bufdelete').delete({ buf = self.tree.buf, force = true })
      require('vv-utils.ui_window').show_chrome(win)
      vim.wo[win].winfixwidth = false
      vim.wo[win].winhighlight = vim.api.nvim_get_option_value('winhighlight', { scope = 'global' })
      return
    end
  end
  self.tree:close()
end
---查询实际窗口是否存在
function View:is_open() return self.tree:is_open() end

---更新筛选；kinds=false 表示全部，nil 表示保持现值
---@param opts {query?:string,mode?:string,kinds?:string[]|false}
function View:set_filter(opts)
  if opts.query ~= nil then self.query = opts.query end
  if opts.mode ~= nil then self.mode = opts.mode end
  if opts.kinds ~= nil then self.kinds = opts.kinds or nil end
  apply_filter(self)
end

---关闭 owning 输入框；不会触发取消回调
function View:close_prompt()
  local prompt = self.prompt
  self.prompt = nil
  if prompt then
    vim.cmd.stopinsert()
    prompt.close()
  end
end

---以现有 vv 输入交互实时筛选，Esc 恢复打开输入前的已接受查询
function View:filter()
  if not self:is_open() then return end
  self:close_prompt()
  local before = { query = self.query, mode = self.mode }
  local function focus()
    if self:is_open() then vim.api.nvim_set_current_win(self.tree.win) end
  end
  self.prompt = Prompt.open(self.tree.win, {
    debounce = self.opts.config.filter.debounce_ms,
    initial = self.query,
    filetype = 'vv-symbols-filter',
    get_mode = function() return self.mode end,
    get_status = function() return self.valid and (self.count .. ' matches') or 'Invalid regex' end,
    on_input = function(query) self.query = query end,
    on_change = function(query) self:set_filter({ query = query }) end,
    on_cycle_mode = function() self:set_filter({ mode = Match.next_mode(self.mode) }) end,
    on_accept = function(query)
      self.prompt = nil
      self:set_filter({ query = query })
      focus()
    end,
    on_cancel = function()
      self.prompt = nil
      self:set_filter(before)
    end,
    on_navigate = function(direction)
      local lines = Navigation.lines(self.tree)
      local row = vim.api.nvim_win_get_cursor(self.tree.win)[1]
      local target
      for _, line in ipairs(lines) do
        local node = self.tree.rows[line].node
        if not node.context_only and (direction > 0 and line > row or direction < 0 and line < row) then
          target = line
          if direction > 0 then break end
        end
      end
      if target then
        vim.api.nvim_win_set_cursor(self.tree.win, { target, 0 })
        preview(self, selected(self))
      end
    end,
  })
end

---按当前文档实际存在的类型选择筛选
function View:choose_kind()
  if not action_available(self, 'kind') then return end
  local diagnostics = self.data.mode == 'diagnostics'
  local kinds = diagnostics and { 'All', 'Error', 'Warn', 'Info', 'Hint' } or { 'All', 'Function' }
  local seen = {}
  for _, kind in ipairs(kinds) do
    seen[kind] = true
  end
  for _, node in ipairs(Model.flatten(self.data.nodes)) do
    if not diagnostics and not seen[node.kind] then
      kinds[#kinds + 1] = node.kind
      seen[node.kind] = true
    end
  end
  local buf = self.tree.buf
  vim.ui.select(
    kinds,
    { prompt = diagnostics and 'Diagnostic severity' or 'Symbol kind (Function includes callables)' },
    function(kind)
      if not kind or self.tree.buf ~= buf or not self:is_open() then return end
      self:set_filter({ kinds = kind ~= 'All' and { kind } or false })
    end
  )
end

---返回之前的符号树和筛选
function View:back()
  if not action_available(self, 'back') then return end
  local previous = self.return_to_symbols
  self.return_to_symbols = nil
  if self.opts.on_back then
    self.opts.on_back(previous.buf)
  else
    self.reference_mode = false
    self.data = self.back_data
  end
  self.back_data, self.back_filter = nil, nil
  self:set_filter(previous.filter)
  self.saved_folds = previous.saved_folds
  self.tree.folded = previous.folded
  self.tree:refresh()
  local line = self.tree.node_lines[previous.selected_id]
  if line then vim.api.nvim_win_set_cursor(self.tree.win, { line, 0 }) end
end

--- A new explicit query owns its return context; refreshes keep that context.
function View:begin_list(return_context)
  self.return_to_symbols = return_context or self.pending_return
  self.pending_return = nil
  self.back_data, self.back_filter = nil, nil
  self.query, self.kinds, self.saved_folds = '', nil, nil
  self.tree.folded = {}
end

--- Commit a sole LSP result without creating a sidebar or discarding symbol state.
function View:jump_single(node, win)
  if not win or not vim.api.nvim_win_is_valid(win) then return false end
  local active = self.preview or Preview.new(win)
  if not active:commit(node) then return false end
  self.preview = nil
  if self.reference_mode then self:close() end
  return true
end

---切换或更新文件分组列表；同一列表刷新保留筛选
function View:show(data)
  if not self.reference_mode then
    self.back_data = self.data
    self.back_filter = { query = self.query, mode = self.mode, kinds = self.kinds or false }
  end
  if self.data.mode ~= data.mode then
    self:close_prompt()
    restore_preview(self)
    self.query, self.kinds = '', nil
  end
  self.reference_mode = true
  self.data = data
  source_window(self)
  apply_filter(self)
  Navigation.focus_result(self.tree)
end

return M

---@class VVSymbolsView
---@field tree VVTreePanel
---@field data table
---@field reference_mode? boolean
---@field prompt? VVPromptHandle
