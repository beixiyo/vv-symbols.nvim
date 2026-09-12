-- vv-symbols.exports 真实 Tree-sitter 导出识别回归

local source = debug.getinfo(1, 'S').source:sub(2)
local tests_dir = vim.fn.fnamemodify(source, ':p:h')
local root = vim.fn.fnamemodify(tests_dir, ':h')
local vendors = vim.fn.fnamemodify(root, ':h')
vim.opt.runtimepath:prepend(root)
vim.opt.runtimepath:prepend(vendors .. '/vv-utils.nvim')
vim.opt.runtimepath:prepend(vim.fn.stdpath('data') .. '/site')

local Model = require('vv-symbols.model')
local Lens = require('vv-symbols.lens')
local Config = require('vv-symbols.config')
assert(Config.normalize().lens.scope == 'exported')
assert(Config.normalize({ lens = { enabled = false } }).lens.enabled == false, 'lens can be disabled')
local buf = vim.api.nvim_create_buf(false, true)
vim.bo[buf].filetype = 'typescript'
vim.api.nvim_buf_set_name(buf, '/tmp/vv-symbols-exports.ts')
vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
  'export function api() {',
  '  function nested() {}',
  '  const localArrow = () => 1',
  '}',
  'function localFn() {}',
  'export const value = 1',
  'const later = 2',
  'export { later as alias }',
  "import { external } from 'pkg'",
  'export { external as exposed }',
  'export default class Box {',
  '  public run() {}',
  '  private hide() {}',
  '  #secret() {}',
  '  protected shield() {}',
  '  plain() {}',
  '}',
  '// export function fake() {}',
})

local function position(line, character) return { line = line, character = character } end
local function symbol(name, kind, line, start_col, end_col, children)
  return {
    name = name,
    kind = kind,
    range = { start = position(line, 0), ['end'] = position(line, end_col + 1) },
    selectionRange = { start = position(line, start_col), ['end'] = position(line, end_col) },
    children = children,
  }
end

local fn = vim.lsp.protocol.SymbolKind.Function
local variable = vim.lsp.protocol.SymbolKind.Variable
local class = vim.lsp.protocol.SymbolKind.Class
local method = vim.lsp.protocol.SymbolKind.Method
local roots = Model.normalize({
  buf = buf,
  encoding = 'utf-8',
  symbols = {
    symbol('api', fn, 0, 16, 19, {
      symbol('nested', fn, 1, 11, 17),
      symbol('localArrow', variable, 2, 8, 18),
    }),
    symbol('localFn', fn, 4, 9, 16),
    symbol('value', variable, 5, 13, 18),
    symbol('later', variable, 6, 6, 11),
    symbol('alias', variable, 7, 18, 23),
    symbol('external', variable, 8, 9, 17),
    symbol('Box', class, 10, 21, 24, {
      symbol('run', method, 11, 9, 12),
      symbol('hide', method, 12, 10, 14),
      symbol('#secret', method, 13, 2, 9),
      symbol('shield', method, 14, 12, 18),
      symbol('plain', method, 15, 2, 7),
    }),
    symbol('fake', fn, 17, 17, 21),
  },
})

local by_name = {}
for _, node in ipairs(Model.flatten(roots)) do
  by_name[node.name] = node
end
assert(by_name.api.exported == true)
assert(by_name.value.exported == true)
assert(by_name.later.exported == true, 'declaration exported through an alias should be marked')
assert(by_name.alias.exported == true, 'an exported alias落点 should also be recognized when reported by LSP')
assert(by_name.Box.exported == true)
assert(by_name.run.exported == true and by_name.plain.exported == true, 'public class methods are exported API')
assert(by_name.hide.exported == false and by_name['#secret'].exported == false and by_name.shield.exported == false)
assert(by_name.localFn.exported == false)
assert(
  by_name.nested.exported == false and by_name.localArrow.exported == false,
  'nested locals must not inherit export'
)
assert(by_name.external.exported == false, 'imports re-exported from another module are excluded')
assert(by_name.fake.exported == false, 'comment text must not be parsed as export')

assert(Lens.matches(by_name.api) == true)
assert(Lens.matches(by_name.localFn) == false)
assert(Lens.matches(by_name.localFn, { scope = 'all' }) == true, 'scope all should include callable symbols')
assert(Lens.matches(by_name.run) == true)
assert(Lens.matches(by_name.api, { filter = function(node) return node.name == 'api' end }) == true)
assert(Lens.matches(by_name.api, { filter = function() return false end }) == false)
assert(Lens.matches(by_name.hide, { scope = 'exported', filter = function() return true end }) == false)

vim.api.nvim_buf_delete(buf, { force = true })
print('vv-symbols exports test: ok')
