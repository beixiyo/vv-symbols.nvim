-- peek 浮窗契约：快照内容、多结果切换、确认跳转、取消恢复与过期响应

local source = debug.getinfo(1, 'S').source:sub(2)
local root = vim.fn.fnamemodify(source, ':p:h:h')
vim.opt.runtimepath:prepend(root)
vim.opt.runtimepath:prepend(root .. '/../vv-utils.nvim')
vim.o.columns, vim.o.lines = 160, 40

local requests = {}
package.preload['vv-symbols.lsp'] = function()
  return {
    locations = function(opts, callback)
      requests[#requests + 1] = { opts = opts, callback = callback }
      return function() end
    end,
  }
end

local Peek = require('vv-symbols.peek')

local notices = {}
local original_notify = vim.notify
vim.notify = function(message, level)
  notices[#notices + 1] = { message = message, level = level }
end

local dir = vim.fn.tempname()
vim.fn.mkdir(dir, 'p')
local impl_a = dir .. '/impl-a.lua'
local impl_b = dir .. '/impl-b.lua'
vim.fn.writefile({ 'local a = 1', 'function impl_a()', '  return a', 'end', 'return impl_a' }, impl_a)
vim.fn.writefile({ 'local b = 2', 'function impl_b()', '  return b', 'end', 'return impl_b' }, impl_b)

local source_buf = vim.api.nvim_get_current_buf()
vim.api.nvim_buf_set_name(source_buf, dir .. '/source.lua')
vim.api.nvim_buf_set_lines(source_buf, 0, -1, false, { 'local iface = require("iface")', 'return iface' })
local source_win = vim.api.nvim_get_current_win()
vim.api.nvim_win_set_cursor(source_win, { 1, 6 })

local function location(path, line, col)
  return {
    uri = 'file://' .. path,
    range = { start = { line = line, character = col }, ['end'] = { line = line, character = col + 7 } },
  }
end

local function open(opts)
  opts = opts or {}
  Peek.open({
    method = opts.method or 'implementation',
    buf = source_buf,
    cursor = opts.cursor or { line = 0, byte_col = 6 },
  })
  local request = requests[#requests]
  request.callback(nil, {
    locations = opts.locations,
    count = opts.locations and #opts.locations or 0,
    encoding = 'utf-16',
    client_id = 1,
  })
end

-- 单结果：浮窗打开、快照与光标落点正确
open({ locations = { location(impl_a, 1, 9) } })
assert(Peek.is_open(), '有结果时浮窗应打开')
local peek_win = vim.fn.win_getid(vim.fn.winnr())
assert(peek_win ~= source_win, '浮窗应持有焦点')
local snapshot = vim.api.nvim_win_get_buf(peek_win)
assert(vim.api.nvim_buf_get_lines(snapshot, 0, -1, false)[1] == 'local a = 1', '浮窗应显示目标文件快照')
assert(
  vim.deep_equal(vim.api.nvim_win_get_cursor(peek_win), { 2, 9 }),
  '光标应落在实现 selection 范围起点'
)
assert(vim.bo[snapshot].modifiable == false, '快照 buffer 应为只读')
assert(vim.wo[peek_win].number == true, '浮窗应显示行号')
assert(vim.wo[peek_win].statuscolumn == '', '浮窗不应继承 statuscolumn 自绘（nofile 下只会是空白列）')
assert(vim.api.nvim_buf_is_valid(source_buf) and vim.api.nvim_win_get_buf(source_win) == source_buf, '源窗口不应被替换')

-- 多结果切换：]p / [p 环形切换并复用同一浮窗与快照 buffer
open({ locations = { location(impl_a, 1, 9), location(impl_b, 1, 9) } })
assert(vim.fn.win_getid(vim.fn.winnr()) == peek_win, '新结果应复用同一浮窗')
assert(vim.api.nvim_win_get_buf(peek_win) == snapshot, '复用会话应复用同一快照 buffer')
Peek.select(1)
assert(
  vim.api.nvim_buf_get_lines(snapshot, 0, -1, false)[1] == 'local b = 2',
  ']p 应切换到第二个实现的快照'
)
assert(
  vim.api.nvim_win_get_cursor(peek_win)[1] == 2,
  '切换后光标应落在第二个实现的起始行'
)
Peek.select(1)
Peek.select(1)
assert(
  vim.api.nvim_buf_get_lines(snapshot, 0, -1, false)[1] == 'local b = 2',
  '环形切换三步后应回到第二个实现'
)

local function key(keys)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), 'xt', false)
end

-- q 关闭：浮窗释放、焦点回源窗口
key('q')
assert(not Peek.is_open(), 'q 应关闭浮窗')
assert(vim.api.nvim_get_current_win() == source_win, '关闭后焦点应回源窗口')
assert(not vim.api.nvim_buf_is_valid(snapshot), '快照 buffer 应随浮窗释放')

-- 确认跳转：源窗口加载目标文件并落到实现位置
open({ locations = { location(impl_a, 1, 9) } })
key('<CR>')
assert(not Peek.is_open(), '确认后浮窗应关闭')
assert(vim.api.nvim_get_current_win() == source_win, '确认后焦点应在源窗口')
assert(
  vim.uv.fs_realpath(vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(source_win)))
    == vim.uv.fs_realpath(impl_a),
  '确认应把源窗口切到目标文件'
)
assert(vim.deep_equal(vim.api.nvim_win_get_cursor(source_win), { 2, 9 }), '确认应跳到实现范围起点')
vim.api.nvim_win_set_buf(source_win, source_buf)

-- 零结果：不打开浮窗并给出提示
notices = {}
open({ locations = {} })
assert(not Peek.is_open(), '零结果不应打开浮窗')
assert(#notices == 1 and notices[1].level == vim.log.levels.INFO, '零结果应有 INFO 提示')

-- 过期响应：新请求取消旧请求，慢到的旧结果不得写回
Peek.open({ method = 'implementation', buf = source_buf, cursor = { line = 0, byte_col = 6 } })
local stale = requests[#requests]
Peek.open({ method = 'implementation', buf = source_buf, cursor = { line = 0, byte_col = 6 } })
local current = requests[#requests]
current.callback(nil, {
  locations = { location(impl_b, 1, 9) },
  count = 1,
  encoding = 'utf-16',
  client_id = 1,
})
stale.callback(nil, {
  locations = { location(impl_a, 1, 9) },
  count = 1,
  encoding = 'utf-16',
  client_id = 1,
})
local active = vim.api.nvim_win_get_buf(vim.fn.win_getid(vim.fn.winnr()))
assert(
  vim.api.nvim_buf_get_lines(active, 0, -1, false)[1] == 'local b = 2',
  '迟到的旧响应不得覆盖新结果'
)

-- peek.size：content 按内容自适应，比例只作上限；screen 直接按比例占 editor
local function peek_size(peek)
  Peek.close(true)
  Peek.open({ method = 'implementation', buf = source_buf, cursor = { line = 0, byte_col = 6 }, peek = peek })
  requests[#requests].callback(nil, {
    locations = { location(impl_a, 1, 9) },
    count = 1,
    encoding = 'utf-16',
    client_id = 1,
  })
  local win = vim.fn.win_getid(vim.fn.winnr())
  return vim.api.nvim_win_get_width(win), vim.api.nvim_win_get_height(win)
end
local available = vim.o.lines - vim.o.cmdheight - 2
local width, height = peek_size({ size = 'screen', width_ratio = 0.5, height_ratio = 0.4, border = 'rounded' })
assert(
  width == math.floor(vim.o.columns * 0.5) and height == math.floor(available * 0.4),
  ('size=screen 应按比例占 editor，实际 %dx%d'):format(width, height)
)
width = peek_size({ size = 'content', width_ratio = 0.5, height_ratio = 0.4, border = 'rounded' })
assert(width < math.floor(vim.o.columns * 0.5), 'size=content 的短内容不应撑满宽度上限')
Peek.close(true)

-- 源窗口关闭：浮窗随之关闭
vim.api.nvim_set_current_win(source_win)
vim.cmd('vsplit')
vim.api.nvim_win_close(source_win, false)
assert(not Peek.is_open(), '源窗口关闭后浮窗应一并关闭')

vim.notify = original_notify
print('test_peek: all assertions passed')
