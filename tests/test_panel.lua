-- 面板真实窗口契约：筛选不丢祖先、输入取消、连续分隔线缩放及关闭清理
local root = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
vim.opt.rtp:prepend(root)
vim.opt.rtp:prepend(root .. '/../vv-utils.nvim')
vim.opt.rtp:prepend(root .. '/../vv-splits.nvim')
vim.o.columns = 180
vim.o.lines = 45
local Panel = require('vv-symbols.panel')
local source = vim.api.nvim_get_current_buf()
local source_win = vim.api.nvim_get_current_win()
vim.api.nvim_buf_set_lines(source, 0, -1, false, { 'class A {', '  save() {}', '}' })
local range = { start = { line = 1, character = 2 }, ['end'] = { line = 1, character = 6 } }
local child = {
  id = 'save',
  name = 'save',
  kind = 'Method',
  is_callable = true,
  uri = vim.uri_from_bufnr(source),
  buf = source,
  range = range,
  selection_range = range,
  encoding = 'utf-16',
  children = {},
}
local parent = { id = 'A', name = 'A', kind = 'Class', children = { child } }
local closed = 0
local view
view = Panel.new({
  config = require('vv-symbols.config').normalize({ lens = { enabled = false } }),
  on_close = function() closed = closed + 1 end,
  on_refresh = function() end,
  on_references = function()
    view:begin_list()
    view:show({ buf = source, mode = 'references', nodes = { child }, results = {}, status = 'ready' })
  end,
})
view:update({ buf = source, nodes = { parent }, results = {}, status = 'ready' })
view:open()
local win = vim.api.nvim_get_current_win()
local buf = vim.api.nvim_get_current_buf()
-- A long list must scroll independently of the fixed, highlighted toolbar.
local many = {}
for index = 1, 100 do
  many[index] = vim.tbl_extend('force', child, { id = 'item-' .. index, name = 'item-' .. index })
end
view:update({ buf = source, nodes = many, results = {}, status = 'ready' })
local toolbar_win, toolbar_buf = view.tree.toolbar_win, view.tree.toolbar_buf
assert(
  vim.api.nvim_win_get_position(toolbar_win)[1] > vim.api.nvim_win_get_position(win)[1],
  'toolbar must be below the results'
)
local toolbar_position = vim.api.nvim_win_get_position(toolbar_win)
vim.cmd('normal! Gzt')
assert(vim.fn.line('w0') > 1, 'long results must actually scroll')
assert(
  vim.deep_equal(toolbar_position, vim.api.nvim_win_get_position(toolbar_win)),
  'scrolling must not move the toolbar'
)
local key_highlight = false
for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(toolbar_buf, view.tree.toolbar_ns, 0, -1, { details = true })) do
  if mark[4].hl_group == 'Special' then key_highlight = true end
end
assert(key_highlight, 'toolbar keys must have a distinct highlight')
vim.api.nvim_feedkeys('g?', 'xt', false)
local help_win = vim.api.nvim_get_current_win()
assert(help_win ~= win and vim.api.nvim_win_get_config(help_win).relative ~= '', 'g? must open shared floating help')
local help_text = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), '\n')
assert(help_text:find('filter', 1, true), 'help must include actual plugin mappings')
vim.api.nvim_feedkeys('q', 'xt', false)
assert(not vim.api.nvim_win_is_valid(help_win), 'help must close independently')
vim.api.nvim_set_current_win(win)
view:update({ buf = source, nodes = { parent }, results = {}, status = 'ready' })
-- Only symbol-origin references offer a return; all UI reads actual mappings.
local function has_mapping(lhs)
  return vim.api.nvim_buf_call(buf, function() return vim.fn.maparg(lhs, 'n', false, true).buffer == 1 end)
end
assert(has_mapping('R') and has_mapping('F') and not has_mapping('<BS>'), 'symbol actions must exclude back')
view:set_filter({ query = 'save' })
view.saved_folds = { A = true }
vim.api.nvim_win_set_cursor(win, { view.tree.node_lines.save, 0 })
vim.api.nvim_feedkeys('R', 'xt', false)
assert(view.reference_mode and has_mapping('<BS>'), 'symbol references must offer return')
assert(
  not has_mapping('R') and not has_mapping('F') and not has_mapping('t'),
  'reference rows must not expose symbol actions'
)
local reference_hints = table.concat(vim.api.nvim_buf_get_lines(toolbar_buf, 0, -1, false), ' ')
assert(
  reference_hints:find('back to symbols', 1, true) and not reference_hints:find('references', 1, true),
  'toolbar must follow the active actions'
)
vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<BS>', true, false, true), 'xt', false)
assert(not view.reference_mode and view.query == 'save', 'back must restore the symbol query')
assert(vim.api.nvim_win_get_cursor(win)[1] == view.tree.node_lines.save, 'back must restore selected symbol')
view:set_filter({ query = '' })
assert(view.tree.folded.A == true, 'back must preserve pre-filter folds')
view:begin_list()
view:show({ buf = source, mode = 'references', nodes = { child }, results = {}, status = 'ready' })
assert(not has_mapping('<BS>') and not has_mapping('R'), 'direct references must have no invented return history')
view:begin_list()
view:show({ buf = source, mode = 'diagnostics', nodes = { child }, results = {}, status = 'ready' })
assert(
  has_mapping('t') and not has_mapping('F') and not has_mapping('<BS>'),
  'diagnostics offer severity but no symbol navigation'
)
view.reference_mode = false
view:update({ buf = source, nodes = { parent }, results = {}, status = 'ready' })
view:set_filter({ query = 'save', kinds = { 'Function' } })
local lines = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), '\n')
assert(lines:find('save', 1, true) and lines:find('A', 1, true), lines)
local width = vim.api.nvim_win_get_width(win)
require('vv-splits').setup({ mux = false, amount = 1 })
for _ = 1, 12 do
  assert(require('vv-splits').resize({ direction = 'right' }))
end
assert(vim.api.nvim_win_get_width(win) == width + 12, 'resize must keep moving')
view:update({ buf = source, nodes = { parent }, results = {}, status = 'ready' })
assert(vim.api.nvim_win_get_width(win) == width + 12, 'render must not restore configured width')
view:filter()
assert(vim.bo.filetype == 'vv-symbols-filter', 'uses shared editable filter input')
local prompt_buf = vim.api.nvim_get_current_buf()
vim.api.nvim_buf_set_lines(prompt_buf, 1, 2, false, { 'missing' })
vim.api.nvim_exec_autocmds('TextChanged', { buffer = prompt_buf })
assert(
  vim.wait(
    1000,
    function() return not table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), '\n'):find('save', 1, true) end
  ),
  'filter should update after the configured debounce'
)
lines = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), '\n')
assert(not lines:find('save', 1, true), lines)
vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<Esc>', true, false, true), 'xt', false)
vim.wait(50, function() return not vim.api.nvim_buf_is_valid(prompt_buf) end)
assert(not vim.api.nvim_buf_is_valid(prompt_buf), 'cancel closes prompt')
lines = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), '\n')
assert(lines:find('save', 1, true), 'cancel restores accepted filter')
vim.api.nvim_set_current_win(source_win)
vim.cmd('rightbelow vsplit')
local other_win = vim.api.nvim_get_current_win()
local other = vim.api.nvim_create_buf(true, false)
vim.api.nvim_buf_set_name(other, '/tmp/vv-symbols-panel-other.lua')
vim.api.nvim_buf_set_lines(other, 0, -1, false, { 'function save()', 'end' })
vim.api.nvim_win_set_buf(other_win, other)
local other_node = vim.deepcopy(child)
other_node.buf, other_node.uri = other, vim.uri_from_bufnr(other)
other_node.selection_range = { start = { line = 0, character = 9 }, ['end'] = { line = 0, character = 13 } }
view:update({ buf = other, nodes = { other_node }, results = {}, status = 'ready' })
vim.api.nvim_set_current_win(win)
vim.api.nvim_win_set_cursor(win, { 2, 0 })
vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<CR>', true, false, true), 'xt', false)
assert(vim.api.nvim_get_current_win() == other_win, 'jump must target the new source window')
assert(vim.api.nvim_win_get_buf(source_win) == source, 'jump must preserve the original source window')
view:close()
view:close()
assert(closed == 1 and not vim.api.nvim_buf_is_valid(buf), 'idempotent close')
assert(
  not vim.api.nvim_win_is_valid(toolbar_win) and not vim.api.nvim_buf_is_valid(toolbar_buf),
  'close must release the shared toolbar'
)
print('PASS panel filter, input, resize and cleanup')
