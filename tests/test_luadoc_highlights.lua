-- 回归：LuaDoc spell 捕获与引用标记不得破坏语法配色
local root = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
vim.opt.runtimepath:prepend(root)
vim.opt.runtimepath:prepend(vim.fn.fnamemodify(root, ':h') .. '/vv-utils.nvim')

for _, lang in ipairs({ 'lua', 'luadoc' }) do
  if not pcall(vim.treesitter.language.add, lang) then
    print('SKIP: LuaDoc 高亮需要 ' .. lang .. ' parser')
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
assert(keyword == '@type', '非视觉 nospell 捕获不得遮蔽注解关键字')
assert(qualified_type == 'troubleConfig', '限定名 LuaDoc 类型应保留语法高亮')

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
  '引用范围不得覆盖下划线之下的类型捕获'
)
Rows.set_rendered_lines(buf, ns, Rows.render(row))
local found = false
for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
  local groups = mark[4].hl_group
  -- extmark 检查只返回高亮栈的顶层组
  if groups == 'VVSymbolsReferenceMatch' then
    local text = vim.api.nvim_buf_get_text(buf, mark[2], mark[3], mark[4].end_row, mark[4].end_col, {})
    assert(text[1] == 'PackSpec', '叠加高亮必须恰好覆盖被引用类型')
    found = true
  end
end
assert(found, '引用下划线与语法高亮应同时作用于真实 buffer')
local style = vim.api.nvim_get_hl(0, { name = 'VVSymbolsReferenceMatch', link = false })
assert(
  not style.underline and not style.fg and not style.bg,
  '列表引用标记保持无视觉样式；下划线只属于 preview'
)
require('vv-symbols').disable()
vim.api.nvim_buf_delete(buf, { force = true })
print('PASS: LuaDoc 语法与引用高亮')
