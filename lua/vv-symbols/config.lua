-- 公共配置默认值与边界校验；内部模块只接收归一化配置
local M = {}

---归一化配置，不修改调用方对象。默认值见 VVSymbolsConfig 与 README
---@param opts? table
---@return VVSymbolsConfig
function M.normalize(opts)
  local config = vim.tbl_deep_extend('force', {
    panel = { width = 42, position = 'left', preview = true, state = false },
    filter = { mode = 'subseq', kinds = false, debounce_ms = 150 },
    lens = { enabled = true, scope = 'exported', position = 'eol', label = 'refs' },
    locations = { jump_single_result = true },
    references = { concurrency = 4, max_symbols = 200, include_declaration = false },
    timing = { debounce_ms = 250, timeout_ms = 3000 },
    max_lines = 5000,
    keymaps = {
      j = 'next_item',
      k = 'prev_item',
      ['<Down>'] = 'next_item',
      ['<Up>'] = 'prev_item',
      ['<C-n>'] = 'next_item',
      ['<C-p>'] = 'prev_item',
      h = 'close_node',
      l = 'open_node',
      ['<Left>'] = 'close_node',
      ['<Right>'] = 'open_node',
      ['<CR>'] = 'open',
      gf = 'jump',
      ['<Tab>'] = 'toggle_node',
      zR = 'expand_all',
      zM = 'collapse_all',
      ['/'] = 'filter',
      t = 'kind',
      F = 'functions',
      c = 'clear_filter',
      R = 'references',
      ['<BS>'] = 'back',
      r = 'refresh',
      ['g?'] = 'help',
      q = 'close',
      ['<Esc>'] = 'close',
      ['<2-LeftMouse>'] = 'open',
    },
  }, opts or {})
  for name, value in pairs({
    width = config.panel.width,
    max_lines = config.max_lines,
    concurrency = config.references.concurrency,
    max_symbols = config.references.max_symbols,
    timeout_ms = config.timing.timeout_ms,
  }) do
    assert(type(value) == 'number' and value >= 1 and value % 1 == 0, name .. ' must be a positive integer')
  end
  assert(config.timing.debounce_ms >= 0, 'debounce_ms must be non-negative')
  assert(
    type(config.filter.debounce_ms) == 'number'
      and config.filter.debounce_ms >= 0
      and config.filter.debounce_ms % 1 == 0,
    'filter.debounce_ms must be a non-negative integer'
  )
  assert(config.panel.position == 'left' or config.panel.position == 'right', 'invalid panel position')
  assert(vim.tbl_contains({ 'subseq', 'fixed', 'regex' }, config.filter.mode), 'invalid filter mode')
  assert(config.filter.kinds == false or type(config.filter.kinds) == 'table', 'filter.kinds must be a list or false')
  assert(config.lens.scope == 'exported' or config.lens.scope == 'all', 'invalid lens scope')
  assert(config.lens.position == 'above' or config.lens.position == 'eol', 'lens.position must be above or eol')
  assert(
    type(config.lens.label) == 'function'
      or (type(config.lens.label) == 'string' and config.lens.label ~= ''),
    'lens.label must be a non-empty string or a function'
  )
  assert(type(config.locations.jump_single_result) == 'boolean', 'locations.jump_single_result must be boolean')
  assert(config.lens.filter == nil or type(config.lens.filter) == 'function', 'lens.filter must be a function')
  return config
end

return M

---@class VVSymbolsConfig
---@field locations {jump_single_result:boolean} LSP 位置查询仅一个结果时直接跳转 @default {jump_single_result=true}
---@field panel {width:integer, position:'left'|'right', preview:boolean, state:false|VVStateHandle} 默认 width=42, position='left', preview=true, state=false；state 为调用方注入的宽度持久句柄
---@field filter {mode:'subseq'|'fixed'|'regex', kinds:false|string[], debounce_ms:integer} 默认 mode='subseq', kinds=false（全部）, debounce_ms=150；Function 包含识别出的可调用符号
---@field lens {enabled:boolean, scope:'exported'|'all', position:'above'|'eol', label:string|fun(count:integer?):string, filter?:fun(node:table):boolean, format?:fun(node:table,result:table):string} 默认 enabled=true, scope='exported', position='eol', label='refs'；label 函数形态可按 count 处理单复数；filter 是在 callable 与 scope 判断之后追加的包含条件
---@field references {concurrency:integer,max_symbols:integer,include_declaration:boolean} 默认 concurrency=4, max_symbols=200, include_declaration=false
---@field timing {debounce_ms:integer,timeout_ms:integer} 默认 debounce_ms=250, timeout_ms=3000
---@field max_lines integer 自动分析的文档行数上限 @default 5000
---@field keymaps table<string,string|false> 面板局部快捷键，false 禁用；完整默认表见 README
