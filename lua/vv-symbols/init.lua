-- 公共 facade 与当前文档会话：拥有事件、请求、刷新和 UI 的完整生命周期
local Async = require('vv-utils.async')
local Timer = require('vv-utils.timer')
local Config = require('vv-symbols.config')
local Model = require('vv-symbols.model')
local Lsp = require('vv-symbols.lsp')
local References = require('vv-symbols.references')
local Lens = require('vv-symbols.lens')
local Panel = require('vv-symbols.panel')
local Lists = require('vv-symbols.lists')
local M = {}
local config = Config.normalize()
local enabled = false
local lens_enabled = true
local session, view, group, lists
local refresh_session

local function eligible(buf)
  return buf and vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].buftype == ''
end

local function wanted() return enabled and (lens_enabled or view and view:is_open() and not (lists and lists.context)) end

local function publish(current)
  if session ~= current or not eligible(current.buf) then return end
  if view and view:is_open() and not (lists and lists.context) then view:update(current) end
  if lens_enabled then
    Lens.render({
      buf = current.buf,
      nodes = current.nodes,
      results = current.results,
      format = config.lens.format,
      label = config.lens.label,
      position = config.lens.position,
      scope = config.lens.scope,
      filter = config.lens.filter,
    })
  end
end

local function release_session()
  local old = session
  session = nil
  if not old then return end
  old.scope:dispose()
  old.cancel_debounce()
  Lens.clear(old.buf)
end

local function invalidate(current)
  current.scope:cancel()
  current.revision = current.revision + 1
  current.nodes, current.results = {}, {}
  current.status, current.error = 'loading', nil
  current.tick = nil
  Lens.clear(current.buf)
end

local function source(buf)
  if session and session.buf == buf then return session end
  release_session()
  local current = {
    buf = buf,
    nodes = {},
    results = {},
    status = 'loading',
    revision = 0,
    scope = Async.scope({ cancel_previous = true }),
  }
  current.debounce, current.cancel_debounce = Timer.debounce(function(revision)
    if session == current and current.revision == revision and wanted() then refresh_session(current) end
  end, config.timing.debounce_ms)
  session = current
  return current
end

refresh_session = function(current)
  if session ~= current or not eligible(current.buf) then return end
  invalidate(current)
  current.tick = vim.api.nvim_buf_get_changedtick(current.buf)
  if vim.api.nvim_buf_line_count(current.buf) > config.max_lines then
    current.status, current.error =
      'error', ('Document exceeds %d lines; raise max_lines to analyze'):format(config.max_lines)
    publish(current)
    return
  end
  publish(current)
  -- 这张票据覆盖完整文档快照，包括后续引用队列，而非仅覆盖 symbols 的响应
  local request = current.scope:begin({ key = 'document' })
  local cancel_symbols, cancel_refs
  request:set_cancel(function()
    if cancel_symbols then cancel_symbols() end
    if cancel_refs then cancel_refs() end
  end)
  local function valid()
    return session == current
      and request:is_current()
      and eligible(current.buf)
      and vim.api.nvim_buf_get_changedtick(current.buf) == current.tick
  end
  cancel_symbols = Lsp.symbols({ buf = current.buf, timeout_ms = config.timing.timeout_ms }, function(err, result)
    if not valid() then return end
    if err then
      current.status, current.error = 'error', tostring(err)
      publish(current)
      return
    end
    current.nodes = Model.normalize({
      symbols = result.symbols,
      buf = current.buf,
      client_id = result.client_id,
      encoding = result.encoding,
    })
    current.status, current.error = 'ready', nil
    publish(current)
    if not lens_enabled then return end
    local targets = {}
    for _, node in ipairs(Model.flatten(current.nodes)) do
      if Lens.matches(node, config.lens) then
        targets[#targets + 1] = vim.tbl_extend('force', node, { children = {} })
      end
    end
    cancel_refs = References.start({
      buf = current.buf,
      nodes = targets,
      concurrency = config.references.concurrency,
      max_symbols = config.references.max_symbols,
      include_declaration = config.references.include_declaration,
      timeout_ms = config.timing.timeout_ms,
      on_update = function(results)
        if not valid() then return end
        current.results = results
        publish(current)
      end,
    })
    if not request:is_current() and cancel_refs then cancel_refs() end
  end)
  if not request:is_current() and cancel_symbols then cancel_symbols() end
end

local function make_view()
  return Panel.new({
    config = config,
    on_refresh = function() M.refresh() end,
    on_references = function(node)
      if not node.uri or not node.selection_range then return end
      local buf = vim.uri_to_bufnr(node.uri)
      vim.fn.bufload(buf)
      local pos = node.selection_range.start
      local line = vim.api.nvim_buf_get_lines(buf, pos.line, pos.line + 1, false)[1] or ''
      M.locations({
        method = 'references',
        buf = buf,
        client_id = node.client_id,
        cursor = {
          line = pos.line,
          byte_col = vim.str_byteindex(line, node.encoding or 'utf-16', pos.character, false),
        },
      })
    end,
    on_back = function(buf) M.open({ buf = buf }) end,
    on_close = function()
      if lists then lists:stop() end
      -- 关闭侧栏先取消所有面板发起的工作；启用 lens 时按新快照重新分析可见源码
      release_session()
      if enabled and lens_enabled then
        vim.schedule(function()
          if enabled and lens_enabled and eligible(vim.api.nvim_get_current_buf()) then M.refresh() end
        end)
      end
    end,
  })
end

---打开当前文档符号侧栏。opts.buf 默认当前源码 buffer，focus 默认 true
---@param opts? {buf?:integer,focus?:boolean}
function M.open(opts)
  opts = opts or {}
  if not enabled then M.enable() end
  local buf = opts.buf
    or (eligible(vim.api.nvim_get_current_buf()) and vim.api.nvim_get_current_buf())
    or (session and session.buf)
  if not eligible(buf) then
    vim.notify('vv-symbols: open a source buffer first', vim.log.levels.INFO)
    return
  end
  view = view or make_view()
  local previous_filter = view.reference_mode and view.return_to_symbols and view.return_to_symbols.filter
  view.return_to_symbols = nil
  if lists then lists:stop() end
  view.reference_mode = false
  if view:is_open() and vim.api.nvim_win_get_tabpage(view.tree.win) ~= vim.api.nvim_get_current_tabpage() then
    view:close()
  end
  local original_win = vim.api.nvim_get_current_win()
  local current = source(buf)
  view:update(current)
  if previous_filter then view:set_filter(previous_filter) end
  view:open()
  if opts.focus == false and vim.api.nvim_win_is_valid(original_win) then vim.api.nvim_set_current_win(original_win) end
  if not current.tick or current.tick ~= vim.api.nvim_buf_get_changedtick(buf) then refresh_session(current) end
end

---关闭符号侧栏及输入框，保留启用状态
function M.close()
  if lists then lists:stop() end
  if view then view:close() end
end
---查询侧栏实际窗口
---@return boolean
function M.is_open() return view ~= nil and view:is_open() end
---切换侧栏，参数与 open 相同
---@param opts? {buf?:integer,focus?:boolean}
function M.toggle(opts)
  if M.is_open() then
    M.close()
  else
    M.open(opts)
  end
end

---重新请求当前源码符号和引用；opts.buf 默认当前会话源码
---@param opts? {buf?:integer}
function M.refresh(opts)
  if not enabled then return end
  if lists and lists.context then
    lists:refresh()
    return
  end
  local buf = opts and opts.buf or session and session.buf or vim.api.nvim_get_current_buf()
  if eligible(buf) and wanted() then refresh_session(source(buf)) end
end

---在侧栏开启名称输入
function M.filter()
  if not M.is_open() then M.open() end
  if view and view:is_open() then view:filter() end
end

---设置侧栏筛选；query 默认保持，kinds=false 清除类型限制，mode 默认保持
---@param opts {query?:string,kinds?:string[]|false,mode?:'subseq'|'fixed'|'regex'}
function M.set_filter(opts)
  if not M.is_open() then M.open() end
  if view then view:set_filter(opts) end
end

---查询源码光标下标识符的引用，参数与 locations 相同
function M.references(opts) M.locations(vim.tbl_extend('force', opts or {}, { method = 'references' })) end

local function open_list(ctx, toggle)
  if
    toggle
    and lists
    and lists.context
    and lists.context.kind == ctx.kind
    and lists.context.filter_buf == ctx.filter_buf
    and lists.context.win == ctx.win
    and vim.deep_equal(lists.context.severity, ctx.severity)
    and M.is_open()
  then
    M.close()
    return
  end
  if not enabled then M.enable() end
  if not lens_enabled then release_session() end
  view = view or make_view()
  if view:is_open() and vim.api.nvim_win_get_tabpage(view.tree.win) ~= vim.api.nvim_get_current_tabpage() then
    view:close()
  end
  lists = lists or Lists.new({ view = view, config = config })
  ctx.return_context = view.pending_return
  ctx.source_win = vim.api.nvim_get_current_win()
  if view:is_open() and ctx.source_win == view.tree.win then ctx.source_win = view.tree.source_win end
  lists:open(ctx)
end

local function source_buffer()
  local buf = vim.api.nvim_get_current_buf()
  if eligible(buf) then return buf end
  return view and view.data.buf or session and session.buf
end

---查询源码光标的 LSP 位置，默认 references；cursor 使用零基字节列
---@param opts? {method?:string,buf?:integer,cursor?:table,client_id?:integer}
function M.locations(opts)
  opts = opts or {}
  local buf = opts.buf or vim.api.nvim_get_current_buf()
  if not eligible(buf) then return end
  local cursor = vim.api.nvim_win_get_cursor(0)
  open_list({
    kind = opts.method or 'references',
    buf = buf,
    client_id = opts.client_id,
    cursor = opts.cursor or { line = cursor[1] - 1, byte_col = cursor[2] },
  })
end

---显示诊断；默认整个工作区，buf=0 表示当前文件，toggle 默认 false
---@param opts? {buf?:integer,severity?:table|integer,toggle?:boolean}
function M.diagnostics(opts)
  opts = opts or {}
  local buf = opts.buf == 0 and source_buffer() or opts.buf
  open_list(
    { kind = 'diagnostics', filter_buf = buf, buf = buf or source_buffer(), severity = opts.severity },
    opts.toggle
  )
end

---显示 quickfix；toggle 默认 false
function M.quickfix(opts) open_list({ kind = 'quickfix', buf = source_buffer() }, opts and opts.toggle) end

---显示指定源码窗口的位置列表，win 默认当前窗口
function M.loclist(opts)
  opts = opts or {}
  local win = opts.win or vim.api.nvim_get_current_win()
  open_list({ kind = 'loclist', win = win, buf = vim.api.nvim_win_get_buf(win) }, opts.toggle)
end

---启用引用计数提示（默认定义行末，可配 above），并刷新当前文档
function M.enable_lens()
  lens_enabled = true
  if not enabled then M.enable() end
  local buf = source_buffer()
  if eligible(buf) then refresh_session(source(buf)) end
end
---关闭并清理引用虚拟行；无侧栏时停止分析
function M.disable_lens()
  lens_enabled = false
  Lens.clear_all()
  if not M.is_open() then
    release_session()
  elseif session then
    refresh_session(session)
  end
end

--- 查询某行定义符号的引用计数 chunks，供 ufo 折叠行等外部渲染复用
--- 折叠时 eol 幽灵文本被折叠插件接管，需由调用方把计数拼进折起行
---@param buf? integer 缺省当前 buffer
---@param lnum integer 1-based 行号
---@return table? chunks {{text, hl}, ...}；无可展示结果时返回 nil
function M.reference_chunks(buf, lnum)
  if type(lnum) ~= 'number' or lnum < 1 or lnum % 1 ~= 0 then return nil end
  buf = buf or source_buffer()
  if type(buf) ~= 'number' or not vim.api.nvim_buf_is_valid(buf) then return nil end
  local current = session
  if not current or current.buf ~= buf or type(current.nodes) ~= 'table' then return nil end

  local ok_uri, uri = pcall(vim.uri_from_bufnr, buf)
  if not ok_uri or not uri then return nil end

  local row = lnum - 1
  for _, node in ipairs(Model.flatten(current.nodes)) do
    local start = node.range and node.range.start
    if
      start
      and start.line == row
      and node.uri == uri
      and Lens.matches(node, config.lens)
    then
      local result = current.results[node.id]
      if type(result) == 'table' and result.status == 'ready' then
        return Lens.count_chunks(result, config.lens.label)
      end
      return nil
    end
  end
  return nil
end

---启用事件订阅，幂等；不注册全局快捷键
function M.enable()
  if enabled then return end
  enabled = true
  require('vv-utils.hl').register('VVSymbolsHighlights', {
    VVSymbolsName = { link = 'Normal' },
    VVSymbolsKind = { link = 'Type' },
    VVSymbolsLens = { link = 'Comment' },
    VVSymbolsReferenceIcon = { link = 'Special' },
    -- 列表内引用范围不再加视觉标记（下划线只保留在 preview 侧）
    VVSymbolsReferenceMatch = {},
    VVSymbolsReferenceCount = { link = 'VVSymbolsReferenceIcon' },
    VVSymbolsZeroReferences = { link = 'DiagnosticError' },
    -- 匹配段整段染色（fg+bold+同色下划线）：颜色运行时取主题 @keyword 的 fg（见 apply_preview_hl）
    VVSymbolsPreview = { bold = true, underline = true },
  })

  -- preview 匹配色跟随主题关键字色，不写死色值；两处兜底链均失效时才用内置黄
  local function keyword_fg()
    for _, name in ipairs({ '@keyword', 'Keyword' }) do
      local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = name, link = true })
      if ok and type(hl) == 'table' and hl.fg then return hl.fg end
    end
    return nil
  end

  local function apply_preview_hl()
    local fg = keyword_fg() or '#e5c07b'
    vim.api.nvim_set_hl(0, 'VVSymbolsPreview', {
      bold = true,
      fg = fg,
      underline = true,
      sp = fg,
    })
  end

  apply_preview_hl()
  group = vim.api.nvim_create_augroup('VVSymbols', { clear = true })
  vim.api.nvim_create_autocmd('ColorScheme', { group = group, callback = apply_preview_hl })
  local function follow(ev)
    local buf = ev.buf
    vim.schedule(function()
      if not wanted() or not eligible(buf) or vim.api.nvim_get_current_buf() ~= buf then return end
      if view and view:is_open() and view.reference_mode then return end
      local current = source(buf)
      if not current.tick or current.tick ~= vim.api.nvim_buf_get_changedtick(buf) or ev.event == 'LspAttach' then
        refresh_session(current)
      end
    end)
  end
  vim.api.nvim_create_autocmd({ 'BufEnter', 'LspAttach' }, { group = group, callback = follow })
  vim.api.nvim_create_autocmd({ 'TextChanged', 'TextChangedI', 'BufWritePost', 'LspDetach' }, {
    group = group,
    callback = function(ev)
      local current = session
      if not current or not wanted() then return end
      if ev.buf == current.buf or ev.event == 'BufWritePost' then
        invalidate(current)
        publish(current)
        current.debounce(current.revision)
      end
    end,
  })
  vim.api.nvim_create_autocmd({ 'BufUnload', 'BufWipeout' }, {
    group = group,
    callback = function(ev)
      if session and ev.buf == session.buf then
        release_session()
        if view and view:is_open() and not (lists and lists.context) then
          view:update({ nodes = {}, results = {}, status = 'error', error = 'Source buffer closed' })
        end
      end
    end,
  })
  vim.api.nvim_create_autocmd('VimLeavePre', { group = group, callback = M.disable })
  follow({ buf = vim.api.nvim_get_current_buf(), event = 'enable' })
end

---关闭全部自有窗口、标记、请求和事件，幂等
function M.disable()
  enabled = false
  if group then
    vim.api.nvim_del_augroup_by_id(group)
    group = nil
  end
  pcall(vim.api.nvim_del_augroup_by_name, 'VVSymbolsHighlights')
  release_session()
  if lists then
    lists:stop()
    lists = nil
  end
  if view then
    view:close()
    view = nil
  end
  Lens.clear_all()
end

---归一化配置并启用插件；重复 setup 先释放旧实例
---@param opts? table 默认值见 VVSymbolsConfig
function M.setup(opts)
  local normalized = Config.normalize(opts)
  M.disable()
  config, lens_enabled = normalized, normalized.lens.enabled
  local commands = {
    VVSymbolsOpen = M.open,
    VVSymbolsClose = M.close,
    VVSymbolsToggle = M.toggle,
    VVSymbolsFilter = M.filter,
    VVSymbolsRefresh = M.refresh,
    VVSymbolsReferences = M.references,
    VVSymbolsDiagnostics = M.diagnostics,
    VVSymbolsQuickfix = M.quickfix,
    VVSymbolsLoclist = M.loclist,
    VVSymbolsLensEnable = M.enable_lens,
    VVSymbolsLensDisable = M.disable_lens,
    VVSymbolsEnable = M.enable,
    VVSymbolsDisable = M.disable,
  }
  for name, action in pairs(commands) do
    vim.api.nvim_create_user_command(name, function() action() end, { desc = 'vv-symbols: ' .. name })
  end
  M.enable()
end

---返回配置副本；运行时 lens 开关不修改配置默认值
---@return VVSymbolsConfig
function M.get_config() return vim.deepcopy(config) end

return M
