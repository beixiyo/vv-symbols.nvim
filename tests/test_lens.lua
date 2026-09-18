-- lens 虚拟行回归：headless nvim -u NONE -l tests/test_lens.lua

local source = debug.getinfo(1, 'S').source:sub(2)
local tests_dir = vim.fn.fnamemodify(source, ':p:h')
local root = vim.fn.fnamemodify(tests_dir, ':h')
local vendors = vim.fn.fnamemodify(root, ':h')
vim.opt.runtimepath:prepend(root)
vim.opt.runtimepath:prepend(vendors .. '/vv-utils.nvim')
vim.opt.runtimepath:prepend(vim.fn.stdpath('data') .. '/site')

local Lens = require('vv-symbols.lens')
local Config = require('vv-symbols.config')
local defaults = Config.normalize({})
assert(
  defaults.lens.position == 'eol' and defaults.lens.label == 'refs',
  '默认值必须是 eol 位置加 refs 标签'
)
local buf = vim.api.nvim_create_buf(true, false)
vim.api.nvim_buf_set_name(buf, '/tmp/vv-symbols-lens.lua')
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'function first() end', '  function second() end' })
vim.api.nvim_set_current_buf(buf)
vim.bo[buf].modifiable = false
local uri = vim.uri_from_bufnr(buf)
local own_ns = vim.api.nvim_get_namespaces()['vv-symbols.lens']
local other_ns = vim.api.nvim_create_namespace('vv-symbols.test.other')
vim.api.nvim_buf_set_extmark(buf, other_ns, 0, 0, { virt_text = { { 'other', 'Comment' } } })

local nodes = {
  { id = 'first', uri = uri, is_callable = true, exported = true, range = { start = { line = 0 } } },
  { id = 'first-again', uri = uri, is_callable = true, exported = true, range = { start = { line = 0 } } },
  { id = 'second', uri = uri, is_callable = true, exported = true, range = { start = { line = 1 } } },
  { id = 'skipped', uri = uri, is_callable = true, exported = true, range = { start = { line = 0 } } },
  {
    id = 'foreign',
    uri = 'file:///elsewhere.lua',
    is_callable = true,
    exported = true,
    range = { start = { line = 0 } },
  },
  { id = 'out', uri = uri, is_callable = true, exported = true, range = { start = { line = 99 } } },
}
local count = Lens.render({
  buf = buf,
  nodes = nodes,
  results = {
    first = { status = 'pending' },
    ['first-again'] = { status = 'ready', count = 4 },
    second = { status = 'ready', count = 2 },
    skipped = { status = 'skipped' },
    foreign = { status = 'error', error = 'x' },
    out = { status = 'error', error = 'x' },
  },
  scope = 'all',
  position = 'above',
})
assert(count == 3, '只有 buffer 内支持的行才会创建 extmark')
assert(
  vim.fn.winsaveview().topline == 1 and vim.fn.winsaveview().topfill >= 2,
  '首行可见虚拟行应预留足够 topfill，且不改变视口首行'
)

local own = vim.api.nvim_buf_get_extmarks(buf, own_ns, 0, -1, { details = true })
assert(#own == 3, '每个可见符号应各有一条独立 extmark')
local seen_first, seen_first_again, seen_second = false, false, false
local first_marks = 0
for _, mark in ipairs(own) do
  assert(mark[4].virt_lines_above == true, '引用提示必须位于符号行上方')
  local text = ''
  for _, chunk in ipairs(mark[4].virt_lines[1]) do
    text = text .. chunk[1]
  end
  if mark[2] == 0 then
    first_marks = first_marks + 1
    if text == ' … refs' then seen_first = true end
    if text == ' 4 refs' then
      seen_first_again = true
      assert(
        mark[4].virt_lines[1][2][2] == 'VVSymbolsReferenceCount',
        '引用数字必须独立高亮'
      )
    end
  elseif mark[2] == 1 then
    seen_second = text == '   2 refs'
    assert(mark[4].virt_lines[1][1][1] == '  ', '虚拟行应保留定义行缩进')
  end
end
assert(
  first_marks == 2 and seen_first and seen_first_again and seen_second,
  '同一行的两个提示必须各自可见且文案独立'
)

vim.fn.winrestview({ topfill = 0 })
Lens.render({
  buf = buf,
  nodes = nodes,
  results = {
    first = { status = 'ready', count = 0 },
    ['first-again'] = { status = 'ready', count = 5 },
    second = { status = 'ready', count = 3 },
  },
  scope = 'all',
  position = 'above',
})
assert(
  vim.fn.winsaveview().topline == 1 and vim.fn.winsaveview().topfill == 0,
  '后续刷新不得回收用户手动移除的 topfill'
)
local zero
for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, own_ns, 0, -1, { details = true })) do
  local chunks = mark[4].virt_lines[1]
  if chunks[2][1] == '0' then zero = chunks end
end
assert(zero and zero[2][2] == 'VVSymbolsZeroReferences', '零引用必须使用错误色')
assert(zero[3][2] == 'VVSymbolsLens', '引用标签保持次级配色')

vim.bo[buf].modifiable = true
Lens.clear(buf)
assert(#vim.api.nvim_buf_get_extmarks(buf, own_ns, 0, -1, {}) == 0, 'clear 应释放本模块命名空间的标记')
assert(#vim.api.nvim_buf_get_extmarks(buf, other_ns, 0, -1, {}) == 1, 'clear 不得触碰其它命名空间')

Lens.render({
  buf = buf,
  nodes = { nodes[1] },
  results = { first = { status = 'error', error = 'server failed' } },
  scope = 'all',
  position = 'above',
})
local error_mark = vim.api.nvim_buf_get_extmarks(buf, own_ns, 0, -1, { details = true })[1]
assert(error_mark[4].virt_lines[1][2][1] == '? refs', '错误状态不得渲染成零引用')
Lens.clear_all()
assert(#vim.api.nvim_buf_get_extmarks(buf, own_ns, 0, -1, {}) == 0, 'clear_all should release all tracked marks')

Lens.render({
  buf = buf,
  nodes = { nodes[1] },
  results = { first = { status = 'ready', count = 0 } },
  scope = 'all',
  position = 'eol',
})
local inline = vim.api.nvim_buf_get_extmarks(buf, own_ns, 0, -1, { details = true })[1][4]
assert(inline.virt_text_pos == 'eol' and not inline.virt_lines, '行尾提示必须使用 eol 虚拟文本')
assert(inline.virt_text[2][2] == 'VVSymbolsReferenceIcon', '链接图标必须使用主题高亮')
assert(inline.virt_text[3][2] == 'VVSymbolsZeroReferences', '行内零引用保留红色计数高亮')
Lens.render({ buf = buf, nodes = { nodes[1] }, results = { first = { status = 'ready', count = 2 } }, scope = 'all', position = 'above' })
local above = vim.api.nvim_buf_get_extmarks(buf, own_ns, 0, -1, { details = true })
assert(
  #above == 1 and above[1][4].virt_lines_above and not above[1][4].virt_text,
  '切换位置必须替换旧装饰'
)
assert(above[1][4].virt_lines[1][1][2] == 'VVSymbolsReferenceIcon', '上方虚拟行的图标使用同一高亮')

Lens.render({
  buf = buf,
  nodes = { nodes[2] },
  results = { ['first-again'] = { status = 'ready', count = 7 } },
  scope = 'all',
  label = '引用',
})
local custom = vim.api.nvim_buf_get_extmarks(buf, own_ns, 0, -1, { details = true })[1][4]
assert(
  custom.virt_text_pos == 'eol' and custom.virt_text[#custom.virt_text][1] == ' 引用',
  '默认渲染必须遵循自定义 label'
)
assert(
  vim.tbl_contains(vim.tbl_map(function(chunk) return chunk[1] end, custom.virt_text), '7'),
  '自定义 label 时计数仍需独立 chunk'
)

-- count_chunks：面板与 ufo 折叠行共用的计数 chunks 契约
local ready_chunks = Lens.count_chunks({ status = 'ready', count = 3 })
assert(
  ready_chunks
    and #ready_chunks == 3
    and ready_chunks[2][1] == '3'
    and ready_chunks[2][2] == 'VVSymbolsReferenceCount'
    and ready_chunks[3][1] == ' refs'
    and ready_chunks[3][2] == 'VVSymbolsLens',
  'ready 结果产出图标+数字+标签三段 chunks'
)
assert(
  Lens.count_chunks({ status = 'ready', count = 0 })[2][2] == 'VVSymbolsZeroReferences',
  '零引用沿用错误色高亮'
)
assert(
  Lens.count_chunks({ status = 'ready', count = 1 }, '引用')[3][1] == ' 引用',
  'count_chunks 支持自定义标签'
)
assert(
  Lens.count_chunks({ status = 'pending' }) == nil and Lens.count_chunks({ status = 'error' }) == nil,
  '非 ready 状态不产出 chunks（由调用方自行处理后缀）'
)
assert(
  Lens.count_chunks({ status = 'ready', count = 1 }, function(count) return count == 1 and 'ref' or 'refs' end)[3][1] == ' ref'
    and Lens.count_chunks({ status = 'ready', count = 2 }, function(count) return count == 1 and 'ref' or 'refs' end)[3][1] == ' refs',
  '函数形态 label 可按 count 处理单复数'
)

-- 无导出识别语言的顶层回退：顶层可调用视为模块 API，嵌套符号仍不算
local py_top = { name = 'run', is_callable = true, exported = false, top_level = true, export_undetected = true }
local py_method = { name = 'handle', is_callable = true, exported = false, top_level = false, export_undetected = true }
local js_local = { name = 'helper', is_callable = true, exported = false, top_level = true, export_undetected = false }
assert(Lens.matches(py_top) == true, '无导出识别语言的顶层函数视为模块 API')
assert(Lens.matches(py_method) == false, '无导出识别语言的嵌套方法仍不算导出')
assert(Lens.matches(js_local) == false, '有导出识别的语言仍按源码导出判断，顶层未导出不算')
vim.api.nvim_buf_delete(buf, { force = true })
vim.cmd('qa!')
