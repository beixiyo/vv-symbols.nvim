-- 调度可调用符号的 LSP 引用查询，并维护可供展示的状态快照

local Async = require('vv-utils.async')

local M = {}

local DEFAULT_CONCURRENCY = 4
local DEFAULT_MAX_SYMBOLS = 200
local DEFAULT_TIMEOUT_MS = 3000

local function positive_integer(value, name, default, allow_zero)
  if value == nil then return default end
  assert(type(value) == 'number' and value % 1 == 0, name .. ' must be an integer')
  if allow_zero then
    assert(value >= 0, name .. ' must be non-negative')
  else
    assert(value >= 1, name .. ' must be positive')
  end
  return value
end

local function normalize_opts(opts)
  opts = opts or {}
  assert(type(opts) == 'table', 'references options must be a table')
  assert(opts.nodes == nil or type(opts.nodes) == 'table', 'nodes must be a table')
  assert(opts.on_update == nil or type(opts.on_update) == 'function', 'on_update must be a function')

  return {
    buf = opts.buf,
    nodes = opts.nodes or {},
    concurrency = positive_integer(opts.concurrency, 'concurrency', DEFAULT_CONCURRENCY),
    max_symbols = positive_integer(opts.max_symbols, 'max_symbols', DEFAULT_MAX_SYMBOLS, true),
    timeout_ms = positive_integer(opts.timeout_ms, 'timeout_ms', DEFAULT_TIMEOUT_MS, true),
    include_declaration = opts.include_declaration == true,
    on_update = opts.on_update,
  }
end

local function clone_results(results)
  local snapshot = {}
  for id, result in pairs(results) do
    local copy = {}
    for key, value in pairs(result) do
      if key == 'locations' and type(value) == 'table' then
        copy.locations = vim.deepcopy(value)
      else
        copy[key] = value
      end
    end
    snapshot[id] = copy
  end
  return snapshot
end

local function set_result(results, id, result) results[id] = result end

---开始查询可调用符号的引用
---@param opts? VVSymbolsReferencesStartOpts
---@return fun() cancel
function M.start(opts)
  local config = normalize_opts(opts)
  local Model = require('vv-symbols.model')
  local Lsp = require('vv-symbols.lsp')
  local nodes = Model.flatten(config.nodes) or {}
  local callable = {}
  local results = {}

  for _, node in ipairs(nodes) do
    if node.is_callable == true then callable[#callable + 1] = node end
  end

  for index, node in ipairs(callable) do
    if index > config.max_symbols then
      set_result(results, node.id, { status = 'skipped' })
    else
      set_result(results, node.id, { status = 'pending' })
    end
  end

  local scope = Async.scope({ cancel_previous = true })
  local cancelled = false
  local active = 0
  local next_index = 1
  local pumping = false
  local update_scheduled = false

  local function schedule_update()
    if cancelled or update_scheduled or not config.on_update then return end
    update_scheduled = true
    vim.schedule(function()
      update_scheduled = false
      if cancelled then return end
      config.on_update(clone_results(results))
    end)
  end

  local pump
  local function finish_item(item, request, err, response)
    if item.done then return end
    item.done = true
    active = math.max(0, active - 1)
    if not request:finish() then return end

    if err ~= nil then
      set_result(results, item.node.id, {
        status = 'error',
        error = err,
      })
    elseif
      type(response) ~= 'table'
      or type(response.locations) ~= 'table'
      or type(response.count) ~= 'number'
      or response.count % 1 ~= 0
      or response.count < 0
      or type(response.encoding) ~= 'string'
    then
      set_result(results, item.node.id, {
        status = 'error',
        error = 'invalid references result',
      })
    else
      set_result(results, item.node.id, {
        status = 'ready',
        count = response.count,
        locations = response.locations,
        encoding = response.encoding,
      })
    end

    schedule_update()
    pump()
  end

  local function launch(node)
    active = active + 1
    local item = { node = node }
    local request = scope:begin({ key = node.id, mode = 'parallel' })

    local callback = function(err, response) finish_item(item, request, err, response) end

    local ok, handle = pcall(Lsp.references, {
      buf = config.buf or node.buf,
      client_id = node.client_id,
      uri = node.uri,
      position = node.selection_range.start,
      include_declaration = config.include_declaration,
      timeout_ms = config.timeout_ms,
    }, callback)

    if not ok then
      finish_item(item, request, handle, nil)
    else
      assert(type(handle) == 'function', 'Lsp.references must return a cancel function')
      request:set_cancel(function() pcall(handle) end)
    end
  end

  pump = function()
    if cancelled or pumping then return end
    pumping = true
    while
      not cancelled
      and active < config.concurrency
      and next_index <= config.max_symbols
      and next_index <= #callable
    do
      local node = callable[next_index]
      next_index = next_index + 1
      launch(node)
    end
    pumping = false
  end

  schedule_update()
  pump()

  return function()
    if cancelled then return end
    cancelled = true
    scope:cancel()
  end
end

---@class VVSymbolsReferencesStartOpts
---@field buf? integer 查询所在的 buffer；缺省使用节点的 buf
---@field nodes table 节点树，交由 model.flatten 展平
---@field concurrency? integer 并发请求数 @default 4
---@field max_symbols? integer 最多查询的可调用符号数，超出者为 skipped @default 200
---@field timeout_ms? integer 单个 LSP 请求超时毫秒数 @default 3000
---@field include_declaration? boolean 是否包含声明位置 @default false
---@field on_update? fun(results:table<string|integer, VVSymbolsReferenceResult>)

---@class VVSymbolsReferenceResult
---@field status 'pending'|'ready'|'error'|'skipped'
---@field count? integer
---@field locations? table
---@field error? any
---@field encoding? string

return M
