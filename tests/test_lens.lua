-- lens 虚拟行回归：headless nvim -u NONE -l tests/test_lens.lua

local source = debug.getinfo(1, 'S').source:sub(2)
local tests_dir = vim.fn.fnamemodify(source, ':p:h')
local root = vim.fn.fnamemodify(tests_dir, ':h')
local vendors = vim.fn.fnamemodify(root, ':h')
vim.opt.runtimepath:prepend(root)
vim.opt.runtimepath:prepend(vendors .. '/vv-utils.nvim')
vim.opt.runtimepath:prepend(vim.fn.stdpath('data') .. '/site')

local Lens = require('vv-symbols.lens')
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
})
assert(count == 3, 'only supported in-buffer lines should get extmarks')
assert(
  vim.fn.winsaveview().topline == 1 and vim.fn.winsaveview().topfill >= 2,
  'a visible first-line virtual row should reserve enough topfill without changing the viewport line'
)

local own = vim.api.nvim_buf_get_extmarks(buf, own_ns, 0, -1, { details = true })
assert(#own == 3, 'lens should create one independent mark per visible symbol')
local seen_first, seen_first_again, seen_second = false, false, false
local first_marks = 0
for _, mark in ipairs(own) do
  assert(mark[4].virt_lines_above == true, 'reference status must be above the symbol line')
  local text = ''
  for _, chunk in ipairs(mark[4].virt_lines[1]) do
    text = text .. chunk[1]
  end
  if mark[2] == 0 then
    first_marks = first_marks + 1
    if text == ' … references' then seen_first = true end
    if text == ' 4 references' then
      seen_first_again = true
      assert(
        mark[4].virt_lines[1][2][2] == 'VVSymbolsReferenceCount',
        'reference number must be highlighted separately'
      )
    end
  elseif mark[2] == 1 then
    seen_second = text == '   2 references'
    assert(mark[4].virt_lines[1][1][1] == '  ', 'virtual line should preserve definition indentation')
  end
end
assert(
  first_marks == 2 and seen_first and seen_first_again and seen_second,
  'two same-line lenses must remain independently visible with distinct text'
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
})
assert(
  vim.fn.winsaveview().topline == 1 and vim.fn.winsaveview().topfill == 0,
  'a later refresh must not reclaim a topfill the user manually removed'
)
local zero
for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, own_ns, 0, -1, { details = true })) do
  local chunks = mark[4].virt_lines[1]
  if chunks[2][1] == '0' then zero = chunks end
end
assert(zero and zero[2][2] == 'VVSymbolsZeroReferences', 'zero references must use the error color')
assert(zero[3][2] == 'VVSymbolsLens', 'the references label retains its secondary color')

vim.bo[buf].modifiable = true
Lens.clear(buf)
assert(#vim.api.nvim_buf_get_extmarks(buf, own_ns, 0, -1, {}) == 0, 'clear should release this module namespace marks')
assert(#vim.api.nvim_buf_get_extmarks(buf, other_ns, 0, -1, {}) == 1, 'clear must not touch another namespace')

Lens.render({
  buf = buf,
  nodes = { nodes[1] },
  results = { first = { status = 'error', error = 'server failed' } },
  scope = 'all',
})
local error_mark = vim.api.nvim_buf_get_extmarks(buf, own_ns, 0, -1, { details = true })[1]
assert(error_mark[4].virt_lines[1][2][1] == '? references', 'errors must not be rendered as zero references')
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
assert(inline.virt_text_pos == 'eol' and not inline.virt_lines, 'right-side hints must use end-of-line virtual text')
assert(inline.virt_text[2][2] == 'VVSymbolsReferenceIcon', 'link icon must have its own theme highlight')
assert(inline.virt_text[3][2] == 'VVSymbolsZeroReferences', 'inline zero retains the red count highlight')
Lens.render({ buf = buf, nodes = { nodes[1] }, results = { first = { status = 'ready', count = 2 } }, scope = 'all' })
local above = vim.api.nvim_buf_get_extmarks(buf, own_ns, 0, -1, { details = true })
assert(
  #above == 1 and above[1][4].virt_lines_above and not above[1][4].virt_text,
  'switching positions must replace old decorations'
)
assert(above[1][4].virt_lines[1][1][2] == 'VVSymbolsReferenceIcon', 'above-line icon must use the same highlight')
vim.api.nvim_buf_delete(buf, { force = true })
vim.cmd('qa!')
