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
-- 长列表应独立于固定高亮工具栏滚动
local many = {}
for index = 1, 100 do
  many[index] = vim.tbl_extend('force', child, { id = 'item-' .. index, name = 'item-' .. index })
end
view:update({ buf = source, nodes = many, results = {}, status = 'ready' })
local toolbar_win, toolbar_buf = view.tree.toolbar_win, view.tree.toolbar_buf
assert(
  vim.api.nvim_win_get_position(toolbar_win)[1] > vim.api.nvim_win_get_position(win)[1],
  '工具栏必须位于结果区下方'
)
local toolbar_position = vim.api.nvim_win_get_position(toolbar_win)
vim.cmd('normal! Gzt')
assert(vim.fn.line('w0') > 1, '长结果列表必须真的可滚动')
assert(
  vim.deep_equal(toolbar_position, vim.api.nvim_win_get_position(toolbar_win)),
  '滚动不得移动工具栏'
)
local key_highlight = false
for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(toolbar_buf, view.tree.toolbar_ns, 0, -1, { details = true })) do
  if mark[4].hl_group == 'Special' then key_highlight = true end
end
assert(key_highlight, '工具栏按键应有独立高亮')
vim.api.nvim_feedkeys('g?', 'xt', false)
local help_win = vim.api.nvim_get_current_win()
assert(help_win ~= win and vim.api.nvim_win_get_config(help_win).relative ~= '', 'g? 应打开共享悬浮帮助')
local help_text = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), '\n')
assert(help_text:find('filter', 1, true), '帮助应包含插件实际映射')
vim.api.nvim_feedkeys('q', 'xt', false)
assert(not vim.api.nvim_win_is_valid(help_win), '帮助应能独立关闭')
vim.api.nvim_set_current_win(win)
view:update({ buf = source, nodes = { parent }, results = {}, status = 'ready' })
-- 仅符号入口的引用提供返回；UI 一律读取实际映射
local function has_mapping(lhs)
  return vim.api.nvim_buf_call(buf, function() return vim.fn.maparg(lhs, 'n', false, true).buffer == 1 end)
end
assert(has_mapping('R') and has_mapping('F') and not has_mapping('<BS>'), '符号动作不含返回')
view:set_filter({ query = 'save' })
view.saved_folds = { A = true }
vim.api.nvim_win_set_cursor(win, { view.tree.node_lines.save, 0 })
vim.api.nvim_feedkeys('R', 'xt', false)
assert(view.reference_mode and has_mapping('<BS>'), '符号引用应提供返回')
assert(
  not has_mapping('R') and not has_mapping('F') and not has_mapping('t'),
  '引用行不得暴露符号动作'
)
local reference_hints = table.concat(vim.api.nvim_buf_get_lines(toolbar_buf, 0, -1, false), ' ')
assert(
  reference_hints:find('back to symbols', 1, true) and not reference_hints:find('references', 1, true),
  '工具栏提示须跟随当前可用动作'
)
vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<BS>', true, false, true), 'xt', false)
assert(not view.reference_mode and view.query == 'save', '返回应恢复符号筛选词')
assert(vim.api.nvim_win_get_cursor(win)[1] == view.tree.node_lines.save, '返回应恢复选中的符号')
view:set_filter({ query = '' })
assert(view.tree.folded.A == true, '返回应保留筛选前的折叠状态')
view:begin_list()
view:show({ buf = source, mode = 'references', nodes = { child }, results = {}, status = 'ready' })
assert(not has_mapping('<BS>') and not has_mapping('R'), '直接打开的引用不得凭空提供返回历史')
view:begin_list()
view:show({ buf = source, mode = 'diagnostics', nodes = { child }, results = {}, status = 'ready' })
assert(
  has_mapping('t') and not has_mapping('F') and not has_mapping('<BS>'),
  '诊断提供严重级筛选但无符号导航'
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
assert(vim.api.nvim_win_get_width(win) == width + 12, '连续缩放应持续生效')
view:update({ buf = source, nodes = { parent }, results = {}, status = 'ready' })
assert(vim.api.nvim_win_get_width(win) == width + 12, '重渲染不得恢复配置宽度')
view:filter()
assert(vim.bo.filetype == 'vv-symbols-filter', '使用共享的可编辑筛选输入')
local prompt_buf = vim.api.nvim_get_current_buf()
vim.api.nvim_buf_set_lines(prompt_buf, 1, 2, false, { 'missing' })
vim.api.nvim_exec_autocmds('TextChanged', { buffer = prompt_buf })
assert(
  vim.wait(
    1000,
    function() return not table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), '\n'):find('save', 1, true) end
  ),
  '筛选应按配置的 debounce 生效'
)
lines = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), '\n')
assert(not lines:find('save', 1, true), lines)
vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<Esc>', true, false, true), 'xt', false)
vim.wait(50, function() return not vim.api.nvim_buf_is_valid(prompt_buf) end)
assert(not vim.api.nvim_buf_is_valid(prompt_buf), '取消应关闭输入框')
lines = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), '\n')
assert(lines:find('save', 1, true), '取消应恢复已生效的筛选')
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
assert(vim.api.nvim_get_current_win() == other_win, '跳转应使用新的源码窗口')
assert(vim.api.nvim_win_get_buf(source_win) == source, '跳转不得改动原源码窗口')
view:close()
view:close()
assert(closed == 1 and not vim.api.nvim_buf_is_valid(buf), '重复关闭应幂等')
assert(
  not vim.api.nvim_win_is_valid(toolbar_win) and not vim.api.nvim_buf_is_valid(toolbar_buf),
  '关闭应释放共享工具栏'
)
print('PASS 面板筛选、输入、缩放与清理')
