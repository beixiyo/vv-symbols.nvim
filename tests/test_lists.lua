-- 真实面板验证：grr 查询光标而非外围函数、诊断/quickfix 刷新，以及关闭取消
local root = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
vim.opt.rtp:prepend(root)
vim.opt.rtp:prepend(root .. '/../vv-utils.nvim')
local pending, cancelled = {}, 0
package.loaded['vv-symbols.lsp'] = {
  symbols = function() error('location lists must not require document symbols') end,
  locations = function(opts, callback)
    pending[#pending + 1] = { opts = opts, callback = callback }
    return function() cancelled = cancelled + 1 end
  end,
}
local plugin = require('vv-symbols')
plugin.setup({ lens = { enabled = false }, locations = { jump_single_result = false }, timing = { debounce_ms = 5 } })
local source = vim.api.nvim_get_current_buf()
vim.api.nvim_buf_set_name(source, '/tmp/vv-symbols-list-main.ts')
vim.api.nvim_buf_set_lines(source, 0, -1, false, { 'const localValue = 1', 'consume(localValue)' })
vim.api.nvim_win_set_cursor(0, { 2, 9 })
plugin.references()
assert(#pending == 1 and pending[1].opts.cursor.line == 1 and pending[1].opts.cursor.byte_col == 9)
local range = { start = { line = 1, character = 8 }, ['end'] = { line = 1, character = 18 } }
pending[1].callback(nil, { locations = { { uri = vim.uri_from_bufnr(source), range = range } }, encoding = 'utf-16' })
local buf = vim.api.nvim_get_current_buf()
local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), '\n')
assert(text:find('vv-symbols-list-main.ts', 1, true) and text:find('consume(localValue)', 1, true), text)

local location_ns = vim.api.nvim_get_namespaces()['vv-symbols.locations']
assert(location_ns, 'location lists should own a cursor extmark namespace')
local tracked = vim.api.nvim_buf_get_extmarks(source, location_ns, 0, -1, { details = true })
assert(#tracked == 1 and tracked[1][2] == 1 and tracked[1][3] == 9, 'source cursor should be tracked by byte position')

plugin.refresh()
local shifted_request = pending[#pending]
vim.api.nvim_buf_set_lines(source, 0, 0, false, { '// shifted source' })
vim.api.nvim_exec_autocmds('TextChanged', { buffer = source })
tracked = vim.api.nvim_buf_get_extmarks(source, location_ns, 0, -1, { details = true })
assert(#tracked == 1 and tracked[1][2] == 2, 'inserting a line should move the tracked cursor')
shifted_request.callback(nil, { locations = {}, encoding = 'utf-16' })
text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), '\n')
assert(text:find('Source changed', 1, true), 'an obsolete location response must not replace stale state')

local request_count = #pending
plugin.refresh()
assert(
  #pending == request_count + 1 and pending[#pending].opts.cursor.line == 2,
  'explicit refresh should query the moved source cursor'
)
local shifted_range = { start = { line = 2, character = 8 }, ['end'] = { line = 2, character = 18 } }
pending[#pending].callback(
  nil,
  { locations = { { uri = vim.uri_from_bufnr(source), range = shifted_range } }, encoding = 'utf-16' }
)
text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), '\n')
assert(text:find('consume(localValue)', 1, true), 'a refreshed location response should restore the list')

local target = vim.api.nvim_create_buf(true, false)
vim.api.nvim_buf_set_name(target, '/tmp/vv-symbols-list-target.ts')
vim.api.nvim_buf_set_lines(target, 0, -1, false, { 'target()' })
plugin.refresh()
local target_request = pending[#pending]
target_request.callback(
  nil,
  { locations = { { uri = vim.uri_from_bufnr(target), range = range } }, encoding = 'utf-16' }
)
vim.api.nvim_exec_autocmds('TextChanged', { buffer = target })
assert(
  table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), '\n'):find('Source changed', 1, true),
  'changing a target file should invalidate the location list'
)
request_count = #pending
plugin.refresh()
assert(
  #pending == request_count + 1 and pending[#pending].opts.cursor.line == 2,
  'refresh after a target change should reuse the original source cursor'
)
pending[#pending].callback(nil, { locations = {}, encoding = 'utf-16' })

plugin.close()
assert(
  #vim.api.nvim_buf_get_extmarks(source, location_ns, 0, -1, {}) == 0,
  'closing a list should clear its cursor mark'
)
assert(not plugin.is_open() and cancelled > 0, 'close cancels and cannot reopen')

local ns = vim.api.nvim_create_namespace('vv-symbols-list-test')
vim.diagnostic.set(ns, source, { { lnum = 0, col = 6, end_col = 16, severity = 1, message = 'Example error' } })
plugin.diagnostics({ buf = source })
buf = vim.api.nvim_get_current_buf()
text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), '\n')
assert(text:find('Example error', 1, true), text)
vim.diagnostic.reset(ns, source)
assert(
  vim.wait(
    200,
    function()
      return not table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), '\n'):find('Example error', 1, true)
    end
  ),
  'diagnostic list should refresh'
)
vim.fn.setqflist(
  {},
  'r',
  { title = 'Search test', items = {
    { bufnr = source, lnum = 2, col = 9, text = 'search result' },
  } }
)
plugin.quickfix()
text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), '\n')
assert(text:find('search result', 1, true), text)
-- 在已打开的面板切换列表后，跳转仍使用源码窗口，不能把面板当作目标
for line, value in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
  if value:find('search result', 1, true) then
    vim.api.nvim_win_set_cursor(0, { line, 0 })
    break
  end
end
vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<CR>', true, false, true), 'xt', false)
assert(vim.api.nvim_get_current_buf() == source, 'quickfix jump must use the source window')
assert(vim.deep_equal(vim.api.nvim_win_get_cursor(0), { 2, 8 }), 'quickfix columns are one-based bytes')
local source_win = vim.api.nvim_get_current_win()
vim.fn.setloclist(source_win, {}, 'r', { items = { { bufnr = source, lnum = 1, col = 7, text = 'window location' } } })
plugin.loclist({ win = source_win })
text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), '\n')
assert(text:find('window location', 1, true), text)
plugin.close()
vim.api.nvim_set_current_win(source_win)
plugin.references()
local stale = pending[#pending]
vim.api.nvim_buf_set_lines(source, 0, 0, false, { '// shifted source' })
stale.callback(nil, { locations = { { uri = vim.uri_from_bufnr(source), range = range } }, encoding = 'utf-16' })
text = table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_get_current_buf(), 0, -1, false), '\n')
assert(text:find('Source changed', 1, true), 'changed snapshot cannot publish outdated positions')
vim.api.nvim_set_current_win(source_win)
vim.cmd('split')
local owner_win = vim.api.nvim_get_current_win()
vim.fn.setloclist(owner_win, {}, 'r', { items = { { bufnr = source, lnum = 1, col = 7, text = 'owner test' } } })
plugin.loclist({ win = owner_win })
vim.api.nvim_win_close(owner_win, true)
assert(pcall(plugin.refresh), 'refresh with an invalid loclist owner must not throw')
plugin.disable()
print('PASS caret locations, diagnostics, quickfix and cancellation')
