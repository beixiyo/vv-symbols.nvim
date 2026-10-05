-- Ctrl+鼠标的定义跳转与悬停下划线：拥有 <C-LeftMouse> / <C-MouseMove> 全局映射、下划线 extmark、
-- 清除用的 on_key 订阅与 'mousemoveevent' 的开启
-- 下划线只按当前行文本与 buffer 的 'iskeyword' 计算标识符范围，不发 LSP 请求；不映射普通 <MouseMove>，
-- on_key 只在下划线可见期间订阅，松开 Ctrl 后的下一次普通移动或任意按键即清除并退订
local M = {}

local NS = vim.api.nvim_create_namespace('vv-symbols.mouse')
local CLEAR_NS = vim.api.nvim_create_namespace('vv-symbols.mouse.clear')
local CLICK, MOVE = '<C-LeftMouse>', '<C-MouseMove>'
local MOVE_CODE = vim.keycode(MOVE)
local DESC = { [CLICK] = 'vv-symbols: go to definition', [MOVE] = 'vv-symbols: underline definition link' }
-- 高于语义 token（125），下划线不被语法高亮覆盖
local PRIORITY = 200

local owned = {} ---@type table<string, table> 本模块安装且仍持有的全局映射
local handlers = {} ---@type table<string, fun()> 处理函数 id → 回调
local mark ---@type {buf:integer,row:integer,start_col:integer,end_col:integer}?
local enabled_mousemoveevent = false
local on_definition ---@type fun(ctx:VVSymbolsMouseContext)?

local function global_map(lhs)
  for _, map in ipairs(vim.api.nvim_get_keymap('n')) do
    if map.lhs == lhs then return map end
  end
end

local function has_definition(buf) return #vim.lsp.get_clients({ bufnr = buf, method = 'textDocument/definition' }) > 0 end

---解析鼠标落点：只接受非浮动窗口里普通文件 buffer 的文本区（排除状态栏、分隔线、行号与 sign 列）
---@return {win:integer,buf:integer,row:integer,col:integer}?
local function target()
  local pos = vim.fn.getmousepos()
  local win = pos.winid
  if win == 0 or pos.line == 0 or not vim.api.nvim_win_is_valid(win) then return end
  if vim.api.nvim_win_get_config(win).relative ~= '' then return end
  local buf = vim.api.nvim_win_get_buf(win)
  if vim.bo[buf].buftype ~= '' then return end
  local info = vim.fn.getwininfo(win)[1]
  if not info or pos.wincol <= info.textoff then return end
  return { win = win, buf = buf, row = pos.line - 1, col = pos.column - 1 }
end

---落点所在标识符的零基字节范围 [start, end)；按目标 buffer 的 'iskeyword' 判定
---@return integer? start_col
---@return integer? end_col
local function word_range(t)
  local line = vim.api.nvim_buf_get_lines(t.buf, t.row, t.row + 1, false)[1]
  if not line or t.col >= #line then return end
  local found = vim.api.nvim_buf_call(
    t.buf,
    function() return vim.fn.matchstrpos(line, ('\\k*\\%%%dc\\k\\+'):format(t.col + 1)) end
  )
  if found[2] < 0 then return end
  return found[2], found[3]
end

local function clear()
  local current = mark
  mark = nil
  vim.on_key(nil, CLEAR_NS)
  if current and vim.api.nvim_buf_is_valid(current.buf) then vim.api.nvim_buf_clear_namespace(current.buf, NS, 0, -1) end
end

-- 任意非 Ctrl 移动的按键都结束下划线；回调里不改 buffer，排到主循环再清，且只清触发时那一个下划线
local function on_key(_, typed)
  if typed == MOVE_CODE then return end
  local current = mark
  vim.schedule(function()
    if mark == current then clear() end
  end)
end

local function on_move()
  local t = target()
  if t and mark and mark.buf == t.buf and mark.row == t.row and t.col >= mark.start_col and t.col < mark.end_col then
    return
  end

  local start_col, end_col
  if t and has_definition(t.buf) then start_col, end_col = word_range(t) end
  clear()
  if not start_col then return end

  vim.api.nvim_buf_set_extmark(t.buf, NS, t.row, start_col, {
    end_col = end_col,
    hl_group = 'VVSymbolsLink',
    priority = PRIORITY,
  })
  mark = { buf = t.buf, row = t.row, start_col = start_col, end_col = end_col }
  vim.on_key(on_key, CLEAR_NS)
end

local function on_click()
  local t = target()
  if not t or not has_definition(t.buf) then return end
  clear()
  vim.api.nvim_set_current_win(t.win)
  vim.api.nvim_win_set_cursor(t.win, { t.row + 1, t.col })
  -- 空白或行尾只移动光标，与普通单击一致；落在标识符上才查询定义
  if word_range(t) and on_definition then on_definition({ buf = t.buf, win = t.win }) end
end

local function accept_click()
  local t = target()
  return t ~= nil and has_definition(t.buf)
end

---expr 映射：PopUp 菜单可见或落点不归本插件时原样交还按键（rhs 以 lhs 开头，首键不再映射，保留原生行为）
---expr 求值期间有 textlock，不能切窗口或改 extmark，经 <Cmd> 调用处理函数
---<Cmd> 里用不带尖括号的 id 查处理函数：expr 结果会做 keycode 替换，键名本身会被换成按键码
local function map(lhs, id, handler, accept)
  handlers[id] = handler
  vim.keymap.set('n', lhs, function()
    if vim.fn.pumvisible() == 1 or (accept and not accept()) then return lhs end
    return ('<Cmd>lua require("vv-symbols.mouse")._run(%q)<CR>'):format(id)
  end, { expr = true, desc = DESC[lhs] })
  owned[lhs] = global_map(lhs)
end

---@param id string
function M._run(id)
  local handler = handlers[id]
  if handler then handler() end
end

---安装全局鼠标映射，幂等（先 detach 旧安装）；同键已有全局映射时不覆盖，跳过该键
---underline 开启且 'mousemoveevent' 关闭时打开它（终端只在该选项开启时上报无按键的移动）
---@param opts {goto_definition:boolean,underline:boolean,on_definition:fun(ctx:VVSymbolsMouseContext)}
function M.attach(opts)
  M.detach()
  on_definition = opts.on_definition
  if opts.goto_definition and not global_map(CLICK) then map(CLICK, 'click', on_click, accept_click) end
  if opts.underline and not global_map(MOVE) then
    map(MOVE, 'move', on_move)
    if not vim.o.mousemoveevent then
      vim.o.mousemoveevent = true
      enabled_mousemoveevent = true
    end
  end
end

---移除下划线、on_key 订阅和仍由本模块持有的映射，幂等；映射已被他人改写时保留外部状态
---'mousemoveevent' 仅在由本模块打开、且没有其他 <MouseMove> 全局映射（如 vv-hover）依赖时关回
function M.detach()
  clear()
  for lhs, installed in pairs(owned) do
    local current = global_map(lhs)
    if current and current.callback == installed.callback and current.desc == installed.desc then
      pcall(vim.keymap.del, 'n', lhs)
    end
  end
  owned, handlers, on_definition = {}, {}, nil
  if enabled_mousemoveevent and vim.o.mousemoveevent and not global_map('<MouseMove>') then
    vim.o.mousemoveevent = false
  end
  enabled_mousemoveevent = false
end

return M

---@class VVSymbolsMouseContext
---@field buf integer 被点击的源码 buffer
---@field win integer 被点击的窗口；回调执行时已成为当前窗口，光标已在点击位置
