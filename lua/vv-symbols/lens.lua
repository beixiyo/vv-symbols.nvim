-- 在符号定义行上方绘制引用查询状态的虚拟行

local M = {}
local Model = require('vv-symbols.model')
local namespace = vim.api.nvim_create_namespace('vv-symbols.lens')
local buffers = {}

local function default_format(_, result)
  if type(result) ~= 'table' then return nil end
  if result.status == 'pending' then return '… references' end
  if result.status == 'error' then return '? references' end
  if result.status ~= 'ready' or type(result.count) ~= 'number' then return nil end
  return ('%d reference%s'):format(result.count, result.count == 1 and '' or 's')
end

---判断节点是否应显示引用提示。自定义 filter 不能绕过 callable 与 scope 安全边界
---@param node VVSymbolsNode
---@param opts? {scope?:'exported'|'all',filter?:fun(node:VVSymbolsNode):boolean}
---@return boolean
function M.matches(node, opts)
  opts = opts or {}
  if type(node) ~= 'table' or node.is_callable ~= true then return false end
  local scope = opts.scope or 'exported'
  if scope ~= 'all' and scope ~= 'exported' then return false end
  if scope == 'exported' and node.exported ~= true then return false end
  if opts.filter ~= nil then
    if type(opts.filter) ~= 'function' then return false end
    local ok, result = pcall(opts.filter, node)
    if not ok or result ~= true then return false end
  end
  return true
end

local function buffer_uri(buf)
  local ok, uri = pcall(vim.uri_from_bufnr, buf)
  return ok and uri or nil
end

local function node_line(node)
  local range = node and node.range
  local start = type(range) == 'table' and range.start or nil
  local line = type(start) == 'table' and start.line or nil
  if type(line) ~= 'number' and type(range) == 'table' then line = range.line end
  if type(line) ~= 'number' or line % 1 ~= 0 or line < 0 then return nil end
  return line
end

local function node_belongs_to_buffer(node, uri)
  return type(node) == 'table' and type(node.uri) == 'string' and node.uri == uri
end

local function line_prefix(buf, line)
  local lines = vim.api.nvim_buf_get_lines(buf, line, line + 1, false)
  return (lines[1] or ''):match('^%s*') or ''
end

local function reveal_first_line(buf, required)
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    if vim.api.nvim_win_is_valid(win) then
      local view = vim.api.nvim_win_call(win, vim.fn.winsaveview)
      if view.topline == 1 and view.topfill < required then
        vim.api.nvim_win_call(win, function() vim.fn.winrestview({ topfill = required }) end)
      end
    end
  end
end

---清除指定 buffer 中本模块创建的虚拟行
---@param buf integer
function M.clear(buf)
  if type(buf) ~= 'number' then return end
  if not vim.api.nvim_buf_is_valid(buf) then
    buffers[buf] = nil
    return
  end
  vim.api.nvim_buf_clear_namespace(buf, namespace, 0, -1)
  buffers[buf] = nil
end

---清除所有仍被本模块跟踪的 buffer 中的虚拟行
function M.clear_all()
  local targets = {}
  for buf in pairs(buffers) do
    targets[#targets + 1] = buf
  end
  for _, buf in ipairs(targets) do
    M.clear(buf)
  end
  buffers = {}
end

---为属于指定 buffer 的节点绘制引用计数
---@param opts VVSymbolsLensRenderOpts
---@return integer count 成功创建的 extmark 数量
function M.render(opts)
  assert(type(opts) == 'table', 'lens render options must be a table')
  local buf = opts.buf
  if type(buf) ~= 'number' or not vim.api.nvim_buf_is_valid(buf) then return 0 end
  local nodes = type(opts.nodes) == 'table' and Model.flatten(opts.nodes) or {}
  local results = type(opts.results) == 'table' and opts.results or {}
  local format = opts.format or default_format
  local position = opts.position or 'above'
  assert(type(format) == 'function', 'format must be a function')

  local previous = buffers[buf]
  M.clear(buf)
  local uri = buffer_uri(buf)
  if not uri then return 0 end
  local line_count = vim.api.nvim_buf_line_count(buf)
  local count = 0
  local first_line_count = 0

  for _, node in ipairs(nodes) do
    local result = node and results[node.id]
    local line = node_line(node)
    if
      result
      and result.status ~= 'skipped'
      and line
      and line < line_count
      and node_belongs_to_buffer(node, uri)
      and M.matches(node, opts)
    then
      local ok_text, text = pcall(format, node, result)
      if ok_text and type(text) == 'string' and text ~= '' then
        local prefix = line_prefix(buf, line)
        local chunks = { { text, 'VVSymbolsLens' } }
        if not opts.format and result.status == 'ready' then
          local number = text:match('^%d+')
          if number then
            chunks = {
              { number, result.count == 0 and 'VVSymbolsZeroReferences' or 'VVSymbolsReferenceCount' },
              { text:sub(#number + 1), 'VVSymbolsLens' },
            }
          end
        end
        if not opts.format then
          local ok, icons = pcall(require, 'vv-icons')
          local icon = ok and icons.ns.ui.link or ''
          table.insert(chunks, 1, { icon .. ' ', 'VVSymbolsReferenceIcon' })
        end
        local decoration
        if position == 'eol' then
          table.insert(chunks, 1, { '  ', 'VVSymbolsLens' })
          decoration = { virt_text = chunks, virt_text_pos = 'eol' }
        else
          if prefix ~= '' then table.insert(chunks, 1, { prefix, 'VVSymbolsLens' }) end
          decoration = { virt_lines = { chunks }, virt_lines_above = true }
        end
        local ok_mark = pcall(vim.api.nvim_buf_set_extmark, buf, namespace, line, 0, decoration)
        if ok_mark then
          count = count + 1
          if line == 0 and position == 'above' then first_line_count = first_line_count + 1 end
        end
      end
    end
  end

  if first_line_count > 0 and (not previous or previous.first_line_count == 0) then
    reveal_first_line(buf, first_line_count)
  end
  buffers[buf] = { first_line_count = first_line_count }
  return count
end

---@class VVSymbolsLensRenderOpts
---@field buf integer 目标 buffer
---@field nodes table 节点树或扁平节点列表
---@field results table<string|integer, VVSymbolsReferenceResult>
---@field format? fun(node:table, result:vv-symbols.ReferenceResult):string 自定义一行文本
---@field scope? 'exported'|'all' @default 'exported'
---@field position? 'above'|'eol' 显示在符号上方或定义行末尾 @default 'above'
---@field filter? fun(node:table):boolean 在 callable 与 scope 之后追加的自定义包含条件

return M
