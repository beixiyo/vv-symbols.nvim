-- vv-symbols.model 的 LSP 符号树与过滤行为测试

local this = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p')
local root = vim.fn.fnamemodify(this, ':h:h')
local utils_root = vim.fs.joinpath(vim.fn.fnamemodify(root, ':h'), 'vv-utils.nvim')
vim.opt.runtimepath:prepend(root)
vim.opt.runtimepath:prepend(utils_root)
vim.opt.runtimepath:prepend(vim.fn.stdpath('data') .. '/site')

local Model = require('vv-symbols.model')

local uri = 'file:///workspace/src/main.ts'
local document_buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_name(document_buf, '/workspace/src/main.ts')
local other_buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_name(other_buf, '/workspace/src/other.ts')
local other_uri = vim.uri_from_bufnr(other_buf)

local function position(line, character) return { line = line, character = character } end

local function range(start_line, start_character, end_line, end_character)
  return {
    start = position(start_line, start_character),
    ['end'] = position(end_line, end_character),
  }
end

local function document_symbols()
  return {
    {
      name = 'render',
      kind = vim.lsp.protocol.SymbolKind.Function,
      range = range(0, 0, 10, 0),
      selectionRange = range(0, 9, 0, 15),
      children = {
        {
          name = 'needle',
          kind = vim.lsp.protocol.SymbolKind.Method,
          range = range(2, 2, 4, 3),
          selectionRange = range(2, 2, 2, 8),
        },
        {
          name = 'value',
          kind = vim.lsp.protocol.SymbolKind.Variable,
          range = range(5, 2, 5, 15),
          selectionRange = range(5, 8, 5, 13),
        },
      },
    },
  }
end

local function normalize_document_symbols()
  local roots = Model.normalize({
    symbols = document_symbols(),
    buf = document_buf,
    client_id = 23,
    encoding = 'utf-16',
  })

  assert(#roots == 1)
  assert(roots[1].name == 'render' and roots[1].label == 'render')
  assert(roots[1].kind == 'Function')
  assert(roots[1].lsp_kind == vim.lsp.protocol.SymbolKind.Function)
  assert(roots[1].uri == uri, 'document symbols should use the buffer URI')
  assert(roots[1].buf == document_buf and roots[1].client_id == 23)
  assert(roots[1].encoding == 'utf-16')
  assert(vim.deep_equal(roots[1].range, range(0, 0, 10, 0)))
  assert(vim.deep_equal(roots[1].selection_range, range(0, 9, 0, 15)))
  assert(#roots[1].children == 2)
  assert(#Model.flatten(roots) == 3)
  assert(roots[1].id == Model.normalize({
    symbols = document_symbols(),
    buf = document_buf,
    client_id = 999,
    encoding = 'utf-8',
  })[1].id, 'id should not depend on client metadata')
  assert(roots[1].is_callable == true)
  assert(roots[1].exported == false, 'unsupported filetype should conservatively remain unexported')
  return roots
end

local roots = normalize_document_symbols()

do
  local original = vim.deepcopy(roots)
  local result = Model.filter({ nodes = roots, query = 'ned', mode = 'subseq' })
  assert(result.valid == true)
  assert(result.count == 1 and result.total == 3)
  assert(#result.nodes == 1 and #result.nodes[1].children == 1)
  assert(result.nodes[1].context_only == true)
  assert(result.nodes[1].children[1].name == 'needle')
  assert(result.nodes[1].children[1].context_only ~= true)
  assert(vim.deep_equal(roots, original), 'filter must not modify the input tree')
end

do
  local result = Model.filter({
    nodes = roots,
    query = 'render',
    mode = 'fixed',
    kinds = { 'Function' },
  })
  assert(result.valid == true and result.count == 1 and result.total == 3)
  assert(result.nodes[1].name == 'render')

  local no_match = Model.filter({
    nodes = roots,
    query = 'render',
    mode = 'fixed',
    kinds = { 'Variable' },
  })
  assert(no_match.count == 0 and #no_match.nodes == 0, 'name and kind filters should be combined with AND')

  local function_only = Model.filter({
    nodes = roots,
    query = 'value',
    mode = 'fixed',
    kinds = { 'Function' },
  })
  assert(function_only.count == 0, 'Function filter should not include ordinary variables')

  local all_kinds = Model.filter({ nodes = roots, query = '', kinds = false })
  assert(all_kinds.count == 3 and all_kinds.total == 3, 'false kind filter should mean all kinds')
end

do
  local result = Model.filter({ nodes = roots, query = '[', mode = 'regex' })
  assert(result.valid == false, 'invalid regex should be reported without throwing')
  assert(result.count == 0 and result.total == 3)
end

do
  local symbols = {
    {
      name = 'outside',
      kind = vim.lsp.protocol.SymbolKind.Function,
      location = {
        uri = other_uri,
        range = range(40, 2, 41, 0),
      },
    },
    {
      name = 'inside',
      kind = vim.lsp.protocol.SymbolKind.Variable,
      location = {
        uri = uri,
        range = range(1, 4, 1, 10),
      },
    },
  }
  local roots_from_information = Model.normalize({
    symbols = symbols,
    buf = document_buf,
    client_id = 23,
    encoding = 'utf-8',
  })
  assert(#roots_from_information == 2)
  assert(roots_from_information[1].uri == other_uri)
  assert(roots_from_information[1].buf == other_buf, 'SymbolInformation must use the location buffer across files')
  assert(vim.deep_equal(roots_from_information[1].range, symbols[1].location.range))
  assert(#roots_from_information[1].children == 0, 'SymbolInformation entries must remain flat across locations')
  assert(roots_from_information[2].uri == uri)
end

do
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].filetype = 'typescript'
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
    'const handler = () => 1',
    'const value = 1',
    "const text = '() =>'",
    'const items = list.map(() => 1)',
    'const wrapped = (() => 1) as () => number',
    'const obj = { method: (() => 1) as any }',
  })
  local parser_ok = pcall(vim.treesitter.get_parser, buf, 'typescript')
  local arrow_roots = Model.normalize({
    symbols = {
      {
        name = 'handler',
        kind = vim.lsp.protocol.SymbolKind.Variable,
        range = range(0, 0, 0, 24),
        selectionRange = range(0, 6, 0, 13),
      },
      {
        name = 'value',
        kind = vim.lsp.protocol.SymbolKind.Variable,
        range = range(1, 0, 1, 15),
        selectionRange = range(1, 6, 1, 11),
      },
      {
        name = 'text',
        kind = vim.lsp.protocol.SymbolKind.Variable,
        range = range(2, 0, 2, 20),
        selectionRange = range(2, 6, 2, 10),
      },
      {
        name = 'items',
        kind = vim.lsp.protocol.SymbolKind.Variable,
        range = range(3, 0, 3, 32),
        selectionRange = range(3, 6, 3, 11),
      },
      {
        name = 'wrapped',
        kind = vim.lsp.protocol.SymbolKind.Variable,
        range = range(4, 0, 4, 43),
        selectionRange = range(4, 6, 4, 13),
      },
      {
        name = 'method',
        kind = vim.lsp.protocol.SymbolKind.Property,
        range = range(5, 0, 5, 42),
        selectionRange = range(5, 14, 5, 20),
      },
    },
    buf = buf,
    client_id = 23,
    encoding = 'utf-8',
  })
  if parser_ok then
    assert(arrow_roots[1].is_callable == true, 'a TS variable wrapping an arrow function should be callable')
  end
  assert(arrow_roots[2].is_callable == false)
  assert(arrow_roots[3].is_callable == false, 'string text that resembles an arrow must not trigger callable detection')
  assert(
    arrow_roots[4].is_callable == false,
    'an arrow inside a call argument must not mark the outer variable callable'
  )
  if parser_ok then
    assert(
      arrow_roots[5].is_callable == true,
      'transparent parenthesis and as wrappers should preserve callable detection'
    )
    assert(arrow_roots[6].is_callable == true, 'an object property whose value is an arrow should be callable')
  end

  local callable = Model.filter({
    nodes = arrow_roots,
    query = 'handler',
    mode = 'fixed',
    kinds = { 'Function' },
  })
  assert(callable.count == (parser_ok and 1 or 0))
  vim.api.nvim_buf_delete(buf, { force = true })
end

vim.api.nvim_buf_delete(document_buf, { force = true })
vim.api.nvim_buf_delete(other_buf, { force = true })
print('vv-symbols model test: ok')
