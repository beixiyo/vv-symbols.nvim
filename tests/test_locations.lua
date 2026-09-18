-- vv-symbols.locations / render 的真实 buffer、文件和高亮行为
local source = debug.getinfo(1, 'S').source:sub(2)
local tests_dir = vim.fn.fnamemodify(source, ':p:h')
local root = vim.fn.fnamemodify(tests_dir, ':h')
local vendors = vim.fn.fnamemodify(root, ':h')
vim.opt.runtimepath:prepend(root)
vim.opt.runtimepath:prepend(vendors .. '/vv-utils.nvim')

local Locations = require('vv-symbols.locations')
local Render = require('vv-symbols.render')
local Tree = require('vv-utils.tree_panel')
local UIRows = require('vv-utils.ui_rows')

local buf = vim.api.nvim_create_buf(true, false)
local unsaved_path = vim.fn.tempname() .. '.lua'
vim.api.nvim_buf_set_name(buf, unsaved_path)
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'local café = 1' })
local uri = vim.uri_from_bufnr(buf)

local unsaved = Locations.build({
  items = {
    {
      uri = uri,
      range = { start = { line = 0, character = 6 }, ['end'] = { line = 0, character = 10 } },
      encoding = 'utf-16',
    },
    {
      uri = uri,
      range = { start = { line = 0, character = 12 }, ['end'] = { line = 0, character = 13 } },
      encoding = 'utf-16',
    },
    {
      uri = uri,
      range = { start = { line = 0, character = 6 }, ['end'] = { line = 0, character = 10 } },
      encoding = 'utf-16',
    },
  },
  kind = 'Reference',
})
assert(#unsaved == 1 and #unsaved[1].children == 2, '同文件应只有一个分组，重复位置应去重')
local first = unsaved[1].children[1]
assert(first.code == 'local café = 1' and first.lnum == 1, '已加载 buffer 必须保留源码与行号')
assert(first.byte_col == 6 and first.byte_end_col == 11, 'utf-16 位置必须换算为字节列')
assert(first.name:find('local café', 1, true), '源码文本必须可被搜索')

local disk_root = vim.fn.tempname()
vim.fn.mkdir(disk_root .. '/src/deep', 'p')
local disk_path = disk_root .. '/src/deep/file.lua'
local disk_lines = { 'local value = 1' }
for line = 2, 6001 do
  disk_lines[line] = line == 6001 and 'local remote = 1' or '-- filler'
end
vim.fn.writefile(disk_lines, disk_path)
local disk_uri = vim.uri_from_fname(disk_path)
local diagnostics = Locations.build({
  root = disk_root,
  path = { head = 1, tail = 1 },
  kind = 'Diagnostic',
  items = {
    {
      uri = disk_uri,
      range = { start = { line = 0, character = 6 }, ['end'] = { line = 0, character = 11 } },
      encoding = 'utf-8',
      message = 'first',
      severity = 1,
    },
    {
      uri = disk_uri,
      range = { start = { line = 0, character = 6 }, ['end'] = { line = 0, character = 11 } },
      encoding = 'utf-8',
      message = 'second',
      severity = 2,
    },
    {
      uri = disk_uri,
      range = { start = { line = 6000, character = 6 }, ['end'] = { line = 6000, character = 12 } },
      encoding = 'utf-8',
      message = 'remote',
      severity = 4,
    },
  },
})
assert(#diagnostics == 1 and #diagnostics[1].children == 3, '不同 message 的诊断不得去重')
assert(diagnostics[1].label == 'src/…/file.lua', '展示路径应相对 root 并压缩中段')
assert(diagnostics[1].name == disk_path, '完整路径仍可用于搜索')
assert(diagnostics[1].children[1].code == 'local value = 1', '未加载文件使用有界 readfile 读取源码')
assert(
  diagnostics[1].children[1].kind == 'Error' and diagnostics[1].children[2].kind == 'Warn',
  '诊断严重级应转为可筛选的子节点类型'
)
assert(
  diagnostics[1].children[3].code == 'local remote = 1' and diagnostics[1].children[3].kind == 'Hint',
  '未加载源码也应读取到最远请求行'
)

local warning_row = Render.node({ node = diagnostics[1].children[2], depth = 1, has_children = false, folded = false })
-- 回归：匹配文件名应保留结果行而非空标题
local Model = require('vv-symbols.model')
local by_file = Model.filter({ nodes = diagnostics, query = 'file.lua', mode = 'fixed' })
assert(#by_file.nodes == 1 and #by_file.nodes[1].children == 3, '文件名命中应保留全部文件结果')
local by_path = Model.filter({ nodes = diagnostics, query = 'src/deep', mode = 'fixed', kinds = { 'Warn' } })
assert(#by_path.nodes == 1 and #by_path.nodes[1].children == 1, '路径命中仍须服从严重级过滤')
assert(by_path.nodes[1].children[1].kind == 'Warn', '路径命中不得绕过所选严重级')
local by_message = Model.filter({ nodes = diagnostics, query = 'second', mode = 'fixed' })
assert(#by_message.nodes == 1 and #by_message.nodes[1].children == 1, 'message 命中应只保留匹配行')
assert(by_message.nodes[1].context_only, '未命中的文件头应作为上下文保留')
assert(#diagnostics[1].children == 3, '过滤不得修改源结果')
local warning_hl
for _, chunk in ipairs(warning_row.chunks) do
  if chunk[1]:find('second', 1, true) then warning_hl = chunk[2] end
end
assert(warning_hl == 'DiagnosticWarn', '诊断 message 高亮应跟随严重级')

local quickfix = Locations.build({
  kind = 'Quickfix',
  items = {
    {
      uri = disk_uri,
      range = { start = { line = 0, character = 6 }, ['end'] = { line = 0, character = 11 } },
      encoding = 'utf-8',
      message = 'first result',
    },
    {
      uri = disk_uri,
      range = { start = { line = 0, character = 6 }, ['end'] = { line = 0, character = 11 } },
      encoding = 'utf-8',
      message = 'second result',
    },
  },
})
assert(#quickfix == 1 and #quickfix[1].children == 2, '同一范围的 quickfix message 应保持独立')

local long_file = {
  id = 'long-file',
  name = '/project/src/one/two/three/four/five/six/seven/very_long_file_name.lua',
  label = 'src/…/very_long_file_name.lua',
  display_path = 'src/one/two/three/four/five/six/seven/very_long_file_name.lua',
  kind = 'File',
  file_group = true,
  children = { first },
}
local narrow_file_row = Render.node({
  node = long_file,
  depth = 0,
  has_children = true,
  folded = false,
  panel = { get_width = function() return 42 end },
})
local narrow_header =
  table.concat(vim.tbl_map(function(chunk) return chunk[1] end, UIRows.expand(narrow_file_row)[1].chunks))
assert(
  narrow_header:find('very_long_file_name.lua', 1, true) and narrow_header:find('…', 1, true),
  '窄面板的文件头应压缩路径中段并保留文件名'
)

local row = Render.node({ node = first, depth = 1, has_children = false, folded = false })
local indented = vim.deepcopy(first)
indented.code = '  \tlocal café = 1  \t'
indented.byte_col = first.byte_col + 3
indented.byte_end_col = first.byte_end_col + 3
local trimmed = Render.node({ node = indented, depth = 1 })
local trimmed_text, highlighted = '', ''
for _, chunk in ipairs(trimmed.chunks) do
  trimmed_text = trimmed_text .. chunk[1]
  if type(chunk[2]) == 'table' and vim.tbl_contains(chunk[2], 'VVSymbolsReferenceMatch') then
    highlighted = highlighted .. chunk[1]
  end
end
assert(trimmed_text == '1 │ local café = 1', '引用行应去除源码空白且不加左侧填充')
assert(highlighted == 'café', '去除空白不得破坏多字节引用高亮')
assert(
  indented.byte_col == 9 and indented.code == '  \tlocal café = 1  \t',
  '渲染不得改动原始跳转坐标与源码'
)
local row_text = table.concat(vim.tbl_map(function(chunk) return chunk[1] end, row.chunks))
assert(row_text:find('local café', 1, true), '位置行应保留真实源码文本')
local file_row = Render.node({ node = unsaved[1], depth = 0, has_children = true, folded = false })
assert(
  table.concat(vim.tbl_map(function(chunk) return chunk[1] end, file_row.chunks)):find('(2)', 1, true),
  '文件头应显示子结果数量'
)
local file_lines = UIRows.expand(file_row)
assert(#file_lines == 1, '文件头不得在首个引用前插入空分隔行')
for _, physical in ipairs(file_lines) do
  for _, chunk in ipairs(physical.chunks) do
    assert(not chunk[1]:find('[\r\t]'), '文件头不得包含杂散控制字符')
  end
end

local syntax = Tree.syntax_chunks('local value = 1', 'lua', 'Normal')
local has_capture = false
for _, chunk in ipairs(syntax) do
  if type(chunk[2]) == 'string' and chunk[2]:find('^@') then has_capture = true end
end
assert(has_capture, '可用 parser 应产出捕获高亮')

vim.api.nvim_buf_delete(buf, { force = true })
os.remove(disk_path)
vim.fn.delete(disk_root, 'rf')
print('PASS 位置分组、源码列、路径展示与语法 chunk')
