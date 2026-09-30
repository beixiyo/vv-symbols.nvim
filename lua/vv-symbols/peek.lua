-- vv-symbols.peek — 编排 LSP 位置在 ui_peek 浮窗中的预览会话
--
-- 窗口、快照、高亮与键位机制全部由 vv-utils.ui_peek 提供；本模块只保留
-- 策略：位置请求与过期保护、多结果切换、标题文案与确认跳转

local Lsp = require('vv-symbols.lsp')
local UiPeek = require('vv-utils.ui_peek')

local M = {}

local titles = {
  references = 'References',
  definition = 'Definitions',
  declaration = 'Declarations',
  implementation = 'Implementations',
  type_definition = 'Type definitions',
}

-- 语义 token 属于这些类型时，auto 查 definition 看声明体
local TYPE_TOKENS = { interface = true, type = true, typeParameter = true, enum = true, struct = true }

local state = nil ---@type table? { source_win, method, locations, index, encoding, cancel }
local revision = 0
local configured = nil

local function title(location)
  local label = titles[state.method] or state.method
  local total = state.locations and #state.locations or 1
  local count = total > 1 and (' %d/%d'):format(state.index, total) or ''
  local path = vim.fn.fnamemodify(vim.uri_to_fname(location.uri), ':~:.')
  return ('%s%s · %s:%d'):format(label, count, path, location.range.start.line + 1)
end

---确认当前结果：关闭浮窗并在源窗口跳转，保留 jumplist/tagstack 语义
local function commit()
  local active = state
  if not active or not active.locations then return end
  local location = active.locations[active.index]
  UiPeek.close(false)
  if not location then return end
  if vim.api.nvim_win_is_valid(active.source_win) then
    vim.api.nvim_set_current_win(active.source_win)
  end
  vim.lsp.util.show_document({ uri = location.uri, range = location.range }, active.encoding or 'utf-16', {
    focus = true,
  })
end

---按 peek.size 选择宽高来源；比例基准都是整个 editor 的列数与可用行数
--
-- content：宽度取内容宽度、高度取目标范围 + 10 行（至少半屏），比例只作上限
-- screen：比例即实际宽高，与内容无关
local function geometry(peek)
  local width = { ratio = peek.width_ratio }
  local height = { ratio = peek.height_ratio }
  if peek.size == 'screen' then
    return { width = width, max_width = width, height = height, max_height = height, min_height = 1 }
  end
  return {
    min_width = 60,
    max_width = width,
    height = function(ctx) return ctx.span + 10 end,
    min_height = function(ctx) return math.max(10, math.floor(ctx.screen.available / 2)) end,
    max_height = height,
  }
end

---把动作名键位表翻译为 ui_peek 的 lhs → 回调；false 的项不注册
---@param mapping VVSymbolsPeekKeys
---@return table<string, fun()>
local function keys(mapping)
  local actions = {
    confirm = commit,
    next = function() M.select(1) end,
    prev = function() M.select(-1) end,
  }
  local result = {}
  for action, callback in pairs(actions) do
    if mapping[action] then result[mapping[action]] = callback end
  end
  return result
end

---把 vv-symbols 的 peek 配置翻译为 ui_peek 的几何与键位策略；同表幂等
local function configure(peek)
  if configured == peek then return end
  configured = peek
  UiPeek.setup(vim.tbl_extend('force', geometry(peek), {
    border = peek.border,
    hl = { line = 'CursorLine', range = 'VVSymbolsPreview' },
    on_close = function() state = nil end,
    keys = keys(peek.keys or require('vv-symbols.config').normalize().peek.keys),
  }))
end

local function show(location)
  local info = UiPeek.show({
    uri = location.uri,
    range = location.range,
    encoding = state.encoding,
    title = title(location),
    source_win = state.source_win,
  })
  if not info then
    state = nil
    vim.notify('vv-symbols: failed to read ' .. vim.uri_to_fname(location.uri), vim.log.levels.WARN)
  end
end

---查询并在浮窗预览光标符号的 LSP 位置
---@param opts {method?:string,buf:integer,cursor:{line:integer,byte_col:integer},client_id?:integer,timeout_ms?:integer,peek?:table}
function M.open(opts)
  local method = opts.method or 'implementation'
  if not titles[method] then
    vim.notify(('vv-symbols: peek does not support %s'):format(method), vim.log.levels.WARN)
    return
  end
  configure(opts.peek or require('vv-symbols.config').normalize().peek)

  local current = vim.api.nvim_get_current_win()
  local info = UiPeek.current()
  -- 从浮窗内再次发起时（焦点在 peek），沿用它挂载的源窗口
  local source_win = info and info.win == current and info.source_win or current
  if state and state.source_win ~= source_win then M.close(false) end
  if state and state.cancel then
    state.cancel()
    state.cancel = nil
  end
  if not state then state = { source_win = source_win } end
  state.method = method
  revision = revision + 1
  local token = revision

  local cancel = Lsp.locations({
    method = method,
    buf = opts.buf,
    cursor = opts.cursor,
    client_id = opts.client_id,
    timeout_ms = opts.timeout_ms,
  }, function(err, result)
    if revision ~= token then return end
    state.cancel = nil
    if err then
      M.close(true)
      vim.notify(('vv-symbols: %s'):format(err), vim.log.levels.WARN)
      return
    end
    local locations = result and result.locations or {}
    if #locations == 0 then
      M.close(true)
      local label = method:gsub('(%a)(%u)', '%1 %2'):lower()
      vim.notify(('No %s found'):format(label), vim.log.levels.INFO)
      return
    end
    state.locations = locations
    state.index = 1
    state.encoding = result.encoding
    show(locations[1])
  end)
  if revision == token then state.cancel = cancel end
end

---把 'auto' 解析为具体方法：光标处语义 token 是类型时查 definition，否则 implementation
---
---类型名上 implementation 只返回实现它的 class 或对象字面量，看不到成员声明；
---不用 type_definition：它会把别名解析到底层类型，交叉/联合等匿名类型返回空。
---服务端无语义 token 或 token 未就绪时保持 implementation
---@param buf integer
---@param cursor {line:integer,byte_col:integer} 零基行与字节列
---@return string
function M.resolve_method(buf, cursor)
  for _, token in ipairs(vim.lsp.semantic_tokens.get_at_pos(buf, cursor.line, cursor.byte_col) or {}) do
    if TYPE_TOKENS[token.type] then return 'definition' end
  end
  return 'implementation'
end

---切换预览结果；单结果时无操作，多结果环形切换
---@param delta integer 1 下一个，-1 上一个
function M.select(delta)
  local total = state and state.locations and #state.locations or 0
  if total < 2 or not state.index then return end
  state.index = ((state.index - 1 + delta) % total) + 1
  show(state.locations[state.index])
end

---关闭浮窗、取消进行中的请求；focus_source 默认回源窗口
---@param focus_source? boolean
function M.close(focus_source)
  local active = state
  state = nil
  if active and active.cancel then pcall(active.cancel) end
  UiPeek.close(focus_source)
end

---浮窗是否仍打开
---@return boolean
function M.is_open()
  return state ~= nil and UiPeek.is_open()
end

return M
