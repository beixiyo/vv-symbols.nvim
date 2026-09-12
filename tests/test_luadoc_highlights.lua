-- Regression: LuaDoc spell captures and reference marks must preserve syntax colors.
local root = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
vim.opt.runtimepath:prepend(root)
vim.opt.runtimepath:prepend(vim.fn.fnamemodify(root, ':h') .. '/vv-utils.nvim')

for _, lang in ipairs({ 'lua', 'luadoc' }) do
  if not pcall(vim.treesitter.language.add, lang) then
    print('SKIP: LuaDoc highlighting requires the ' .. lang .. ' parser')
    return
  end
end

local Tree = require('vv-utils.tree_panel')
local Render = require('vv-symbols.render')
local Rows = require('vv-utils.ui_rows')
local chunks = Tree.syntax_chunks('---@type trouble.Config', 'lua')
local keyword, qualified_type = '', ''
for _, chunk in ipairs(chunks) do
  if chunk[2] == '@keyword.luadoc' then keyword = keyword .. chunk[1] end
  if chunk[2] == '@type.luadoc' then qualified_type = qualified_type .. chunk[1] end
end
assert(keyword == '@type', 'nonvisual nospell capture must not mask annotation keywords')
assert(qualified_type == 'troubleConfig', 'qualified LuaDoc types must retain their syntax highlight')

require('vv-symbols').setup({ lens = { enabled = false } })
local row = Render.node({
  depth = 1,
  node = {
    location = true,
    code = '---@type PackSpec',
    lang = 'lua',
    line = 1,
    byte_col = 9,
    byte_end_col = 17,
  },
})
local buf = vim.api.nvim_create_buf(false, true)
local ns = vim.api.nvim_create_namespace('test-luadoc-reference')
local type_chunk = vim.iter(row.chunks):find(function(chunk) return chunk[1] == 'PackSpec' end)
assert(
  type_chunk and vim.deep_equal(type_chunk[2], { '@type.luadoc', 'VVSymbolsReferenceMatch' }),
  'reference range must preserve the type capture below its underline'
)
Rows.set_rendered_lines(buf, ns, Rows.render(row))
local found = false
for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
  local groups = mark[4].hl_group
  -- Extmark inspection returns only the top group of a highlight stack.
  if groups == 'VVSymbolsReferenceMatch' then
    local text = vim.api.nvim_buf_get_text(buf, mark[2], mark[3], mark[4].end_row, mark[4].end_col, {})
    assert(text[1] == 'PackSpec', 'stacked highlight must cover exactly the referenced type')
    found = true
  end
end
assert(found, 'reference underline and syntax must reach the real buffer together')
local style = vim.api.nvim_get_hl(0, { name = 'VVSymbolsReferenceMatch', link = false })
assert(style.underline and not style.fg and not style.bg, 'reference marker must not replace theme colors')
require('vv-symbols').disable()
vim.api.nvim_buf_delete(buf, { force = true })
print('PASS: LuaDoc syntax and reference highlights')
