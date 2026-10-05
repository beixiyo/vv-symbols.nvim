-- 公共配置默认值与边界校验；内部模块只接收归一化配置
local M = {}

local PEEK_METHODS = {
  definition = true,
  declaration = true,
  implementation = true,
  type_definition = true,
  references = true,
}
local PEEK_ACTIONS = { trigger = true, confirm = true, next = true, prev = true }

---归一化配置，不修改调用方对象。默认值见 VVSymbolsConfig 与 README
---@param opts? table
---@return VVSymbolsConfig
function M.normalize(opts)
  local config = vim.tbl_deep_extend('force', {
    panel = { width = 42, position = 'left', preview = true, state = false },
    filter = { mode = 'subseq', kinds = false, debounce_ms = 150 },
    lens = {
      enabled = true,
      scope = 'exported',
      position = 'eol',
      label = 'refs',
      callable_only = false,
    },
    peek = {
      size = 'content',
      width_ratio = 0.8,
      height_ratio = 0.75,
      border = 'rounded',
      method = 'auto',
      keys = { trigger = 'gp', confirm = '<CR>', next = ']p', prev = '[p' },
      hints = true,
    },
    locations = { jump_single_result = true },
    mouse = { goto_definition = true, underline = true },
    quickfix = { replace_native = true },
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
  assert(config.peek.size == 'content' or config.peek.size == 'screen', 'peek.size must be content or screen')

  for _, name in ipairs({ 'width_ratio', 'height_ratio' }) do
    local value = config.peek[name]
    assert(
      type(value) == 'number' and value > 0 and value <= 1,
      ('peek.%s must be a number in (0, 1]'):format(name)
    )
  end

  assert(
    config.peek.method == 'auto' or PEEK_METHODS[config.peek.method],
    'peek.method must be auto, definition, declaration, implementation, type_definition or references'
  )

  -- keys = false 整体禁用：归一化为逐项 false，下游只处理一种形态
  if config.peek.keys == false then
    config.peek.keys = { trigger = false, confirm = false, next = false, prev = false }
  end

  assert(type(config.peek.keys) == 'table', 'peek.keys must be a table or false')

  for action, lhs in pairs(config.peek.keys) do
    assert(PEEK_ACTIONS[action], ('peek.keys.%s is not a known action'):format(action))
    assert(
      lhs == false or (type(lhs) == 'string' and lhs ~= ''),
      ('peek.keys.%s must be a non-empty string or false'):format(action)
    )
  end

  assert(
    type(config.lens.label) == 'function'
      or (type(config.lens.label) == 'string' and config.lens.label ~= ''),
    'lens.label must be a non-empty string or a function'
  )
  -- mouse = false 整体禁用：归一化为逐项 false，下游只处理一种形态
  if config.mouse == false then config.mouse = { goto_definition = false, underline = false } end
  assert(type(config.mouse) == 'table', 'mouse must be a table or false')
  assert(
    type(config.mouse.goto_definition) == 'boolean' or type(config.mouse.goto_definition) == 'function',
    'mouse.goto_definition must be boolean or a function'
  )

  -- 位置列表缺省跟随 lens 计数口径，下游只读取归一化后的 boolean
  if config.locations.include_declaration == nil then
    config.locations.include_declaration = config.references.include_declaration
  end

  return config
end

return M

---@class VVSymbolsConfig
---@field locations VVSymbolsLocationsConfig LSP 位置列表与 peek 的查询行为
---@field mouse VVSymbolsMouseConfig|false Ctrl+鼠标定义跳转与悬停下划线；false 全部关闭
---@field quickfix VVSymbolsQuickfixConfig 原生 quickfix / loclist 窗口接管
---@field panel {width:integer, position:'left'|'right', preview:boolean, state:false|VVStateHandle} 默认 width=42, position='left', preview=true, state=false；state 为调用方注入的宽度持久句柄
---@field filter {mode:'subseq'|'fixed'|'regex', kinds:false|string[], debounce_ms:integer} 默认 mode='subseq', kinds=false（全部）, debounce_ms=150；Function 包含识别出的可调用符号
---@field lens {enabled:boolean, scope:'exported'|'all', position:'above'|'eol', label:string|fun(count:integer?):string, callable_only:boolean, filter?:fun(node:table):boolean, format?:fun(node:table,result:table):string} 默认 enabled=true, scope='exported', position='eol', label='refs', callable_only=false；默认所有导出符号（含变量/常量）都计数，callable_only=true 时仅函数等可调用符号；label 函数形态可按 count 处理单复数；filter 是在 callable 与 scope 判断之后追加的包含条件
---@field peek VVSymbolsPeekConfig 浮窗预览：几何、默认查询方法与快捷键
---@field references {concurrency:integer,max_symbols:integer,include_declaration:boolean} 自动引用计数（lens）：默认 concurrency=4, max_symbols=200, include_declaration=false（计数不含声明位置）
---@field timing {debounce_ms:integer,timeout_ms:integer} 默认 debounce_ms=250, timeout_ms=3000
---@field max_lines integer 自动分析的文档行数上限 @default 5000
---@field keymaps table<string,string|false> 面板局部快捷键，false 禁用；完整默认表见 README

---@class VVSymbolsLocationsConfig
---@field jump_single_result boolean LSP 位置查询仅一个结果时直接跳转 @default true
---@field include_declaration? boolean 位置列表（grr 等）与 peek 的 references 请求是否包含声明；只影响 references，不影响 lens 计数；nil 跟随 references.include_declaration，setup 后总为 boolean @default nil

---@class VVSymbolsMouseConfig
---@field goto_definition boolean|fun(ctx:VVSymbolsMouseContext) 普通模式 Ctrl+左键跳转定义：true 调用 locations({ method = 'definition' })（与 gd 走同一实现），函数则由调用方执行跳转；只在普通文件 buffer、非浮窗且有支持 definition 的 LSP 客户端时拦截，其余位置保留原生 <C-LeftMouse> @default true
---@field underline boolean 按住 Ctrl 移动鼠标时给可跳转的标识符加下划线（VVSymbolsLink）；只按 'iskeyword' 计算范围不发 LSP 请求，'mousemoveevent' 关闭时会将其打开，disable 时按所有权关回 @default true

---@class VVSymbolsQuickfixConfig
---@field replace_native boolean 原生 quickfix/loclist 窗口打开（:copen / :lopen 等）时关闭它，回到所属代码窗口并改开 quickfix() / loclist({ win }) 面板；所属窗口无效或本身是 quickfix 时不接管 @default true

---@class VVSymbolsPeekConfig
---@field size 'content'|'screen' 宽高来源：'content' 按内容自适应、两个比例只作上限；'screen' 直接取比例作为实际宽高 @default 'content'
---@field width_ratio number 宽度比例，基准为 editor 列数 @default 0.8
---@field height_ratio number 高度比例，基准为 editor 可用行数 @default 0.75
---@field border string|table 浮窗边框 @default 'rounded'
---@field method 'auto'|'definition'|'declaration'|'implementation'|'type_definition'|'references' peek() 未传 method 时的查询方法；'auto' 在类型名（interface/type/typeParameter/enum/struct 语义 token）上查 definition 看声明体，其余查 implementation @default 'auto'
---@field keys VVSymbolsPeekKeys|false 快捷键，逐项 false 禁用，整体 false 全部禁用
---@field hints boolean 浮窗底部边框显示按键提示（Jump / Next / Prev / Close，跟随 keys 实际配置；单结果不显示 Next / Prev；窄窗口整条丢弃尾部） @default true

---@class VVSymbolsPeekKeys
---@field trigger string|false 触发 peek 的 buffer-local 键，LSP attach 到普通文件 buffer 时注册（默认会覆盖内置 gp） @default 'gp'
---@field confirm string|false 浮窗内确认跳转 @default '<CR>'
---@field next string|false 浮窗内切到下一个结果 @default ']p'
---@field prev string|false 浮窗内切到上一个结果 @default '[p'
