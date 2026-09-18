-- 回归：分组头不得消耗导航步数，方向键动作不可缺失
local root = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
vim.opt.rtp:prepend(root)
vim.opt.rtp:prepend(root .. '/../vv-utils.nvim')
vim.o.columns, vim.o.lines = 160, 40
local source = vim.api.nvim_get_current_buf()
local other = vim.api.nvim_create_buf(true, false)
vim.api.nvim_buf_set_name(source, '/tmp/vv-nav-a.lua')
vim.api.nvim_buf_set_name(other, '/tmp/vv-nav-b.lua')
for _, buf in ipairs({ source, other }) do
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'local a = 1', 'return a' })
end
local items = {}
for _, buf in ipairs({ source, other }) do
  for line = 0, 1 do
    items[#items + 1] = {
      uri = vim.uri_from_bufnr(buf),
      range = { start = { line = line, character = 0 }, ['end'] = { line = line, character = 5 } },
    }
  end
end
local groups = require('vv-symbols.locations').build({ items = items })
local view = require('vv-symbols.panel').new({
  config = require('vv-symbols.config').normalize({ panel = { preview = false } }),
  on_refresh = function() end,
  on_close = function() end,
  on_references = function() end,
})
view:show({ buf = source, mode = 'references', nodes = groups, status = 'ready' })
view:open()
local tree = view.tree
local function key(value) vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(value, true, false, true), 'xt', false) end
local function current() return tree.rows[vim.api.nvim_win_get_cursor(tree.win)[1]].node.id end
assert(current() == groups[1].children[1].id, '打开后应聚焦第一个结果')
key('j')
assert(current() == groups[1].children[2].id, 'j 应移动到下一个结果')
key('<Down>')
assert(current() == groups[2].children[1].id, 'Down 应跳过已展开的文件头')
key('<Up>')
assert(current() == groups[1].children[2].id, 'Up 应跳过上一个文件头')
key('2j')
assert(current() == groups[2].children[2].id, '计数只统计结果，不含分组行')
key('<Left>')
assert(current() == groups[2].id and tree.folded[groups[2].id], '结果上按 Left 应折叠其文件')
key('k')
assert(current() == groups[1].children[2].id, 'k 应返回上一个结果')
key('j')
assert(current() == groups[2].id, '折叠分组应仍可到达以便展开')
key('<Right>')
assert(
  current() == groups[2].children[1].id and not tree.folded[groups[2].id],
  'Right 应展开并进入第一个结果'
)
key('<Right>')
assert(vim.api.nvim_get_current_win() ~= tree.win, '结果上按 Right 应进入源码')
assert(vim.api.nvim_get_current_buf() == other, 'Right 应打开所选文件')
view:close()
print('PASS 结果导航、计数、折叠分组与方向键动作')
