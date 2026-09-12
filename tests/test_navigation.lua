-- Reproduce group headers consuming navigation steps and missing arrow actions.
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
assert(current() == groups[1].children[1].id, 'opening must focus the first result')
key('j')
assert(current() == groups[1].children[2].id, 'j must visit the next result')
key('<Down>')
assert(current() == groups[2].children[1].id, 'Down must skip the next expanded file header')
key('<Up>')
assert(current() == groups[1].children[2].id, 'Up must skip the previous file header')
key('2j')
assert(current() == groups[2].children[2].id, 'counts must count results, not group rows')
key('<Left>')
assert(current() == groups[2].id and tree.folded[groups[2].id], 'Left on a result must collapse its file')
key('k')
assert(current() == groups[1].children[2].id, 'k must return to the previous result')
key('j')
assert(current() == groups[2].id, 'collapsed groups must stay reachable for expansion')
key('<Right>')
assert(
  current() == groups[2].children[1].id and not tree.folded[groups[2].id],
  'Right must expand and enter the first result'
)
key('<Right>')
assert(vim.api.nvim_get_current_win() ~= tree.win, 'Right on a result must enter source')
assert(vim.api.nvim_get_current_buf() == other, 'Right must open the selected file')
view:close()
print('PASS result navigation, counts, collapsed groups and arrow actions')
