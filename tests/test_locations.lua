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
assert(#unsaved == 1 and #unsaved[1].children == 2, 'same file must have one group and duplicate ranges must collapse')
local first = unsaved[1].children[1]
assert(first.code == 'local café = 1' and first.lnum == 1, 'loaded buffer source and line number are required')
assert(first.byte_col == 6 and first.byte_end_col == 11, 'utf-16 positions must become byte columns')
assert(first.name:find('local café', 1, true), 'source code must be searchable')

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
assert(#diagnostics == 1 and #diagnostics[1].children == 3, 'diagnostics with different messages must not collapse')
assert(diagnostics[1].label == 'src/…/file.lua', 'display path must be relative to root and collapse its middle')
assert(diagnostics[1].name == disk_path, 'full path remains available for searching')
assert(diagnostics[1].children[1].code == 'local value = 1', 'unloaded files use bounded readfile source')
assert(
  diagnostics[1].children[1].kind == 'Error' and diagnostics[1].children[2].kind == 'Warn',
  'diagnostic severity must become filterable child kinds'
)
assert(
  diagnostics[1].children[3].code == 'local remote = 1' and diagnostics[1].children[3].kind == 'Hint',
  'unloaded source must reach the furthest requested line'
)

local warning_row = Render.node({ node = diagnostics[1].children[2], depth = 1, has_children = false, folded = false })
-- Regression: matching a filename must retain its result rows, not an empty heading.
local Model = require('vv-symbols.model')
local by_file = Model.filter({ nodes = diagnostics, query = 'file.lua', mode = 'fixed' })
assert(#by_file.nodes == 1 and #by_file.nodes[1].children == 3, 'filename match must retain all file results')
local by_path = Model.filter({ nodes = diagnostics, query = 'src/deep', mode = 'fixed', kinds = { 'Warn' } })
assert(#by_path.nodes == 1 and #by_path.nodes[1].children == 1, 'path match must still respect severity filtering')
assert(by_path.nodes[1].children[1].kind == 'Warn', 'path match must not bypass the selected severity')
local by_message = Model.filter({ nodes = diagnostics, query = 'second', mode = 'fixed' })
assert(#by_message.nodes == 1 and #by_message.nodes[1].children == 1, 'message match must retain only matching rows')
assert(by_message.nodes[1].context_only, 'an unmatched file header is retained as context')
assert(#diagnostics[1].children == 3, 'filtering must not mutate the source results')
local warning_hl
for _, chunk in ipairs(warning_row.chunks) do
  if chunk[1]:find('second', 1, true) then warning_hl = chunk[2] end
end
assert(warning_hl == 'DiagnosticWarn', 'diagnostic message highlight must follow severity')

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
assert(#quickfix == 1 and #quickfix[1].children == 2, 'quickfix messages at one range must remain distinct')

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
  'narrow file headers should retain the filename while collapsing middle path segments'
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
assert(trimmed_text == '1 │ local café = 1', 'reference rows must trim source whitespace and avoid left padding')
assert(highlighted == 'café', 'trimming tabs and spaces must preserve multibyte reference highlights')
assert(
  indented.byte_col == 9 and indented.code == '  \tlocal café = 1  \t',
  'rendering must retain original jump coordinates and source'
)
local row_text = table.concat(vim.tbl_map(function(chunk) return chunk[1] end, row.chunks))
assert(row_text:find('local café', 1, true), 'location row must retain real source text')
local file_row = Render.node({ node = unsaved[1], depth = 0, has_children = true, folded = false })
assert(
  table.concat(vim.tbl_map(function(chunk) return chunk[1] end, file_row.chunks)):find('(2)', 1, true),
  'file header must show its child count'
)
local file_lines = UIRows.expand(file_row)
assert(#file_lines == 1, 'file header must not insert an empty separator before its first reference')
for _, physical in ipairs(file_lines) do
  for _, chunk in ipairs(physical.chunks) do
    assert(not chunk[1]:find('[\r\t]'), 'file header must not contain stray control characters')
  end
end

local syntax = Tree.syntax_chunks('local value = 1', 'lua', 'Normal')
local has_capture = false
for _, chunk in ipairs(syntax) do
  if type(chunk[2]) == 'string' and chunk[2]:find('^@') then has_capture = true end
end
assert(has_capture, 'available parser must produce capture highlights')

vim.api.nvim_buf_delete(buf, { force = true })
os.remove(disk_path)
vim.fn.delete(disk_root, 'rf')
print('PASS locations grouping, source columns, path display and syntax chunks')
