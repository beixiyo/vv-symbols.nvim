-- LSP document symbol and location requests for vv-symbols.

local Async = require('vv-utils.async')

local M = {}

local DEFAULT_TIMEOUT_MS = 1000
local DOCUMENT_SYMBOL_METHOD = 'textDocument/documentSymbol'
local REFERENCES_METHOD = 'textDocument/references'
local LOCATION_METHODS = {
  references = REFERENCES_METHOD,
  definition = 'textDocument/definition',
  declaration = 'textDocument/declaration',
  implementation = 'textDocument/implementation',
  type_definition = 'textDocument/typeDefinition',
}

local function normalize_options(opts)
  if opts == nil then return {} end
  assert(type(opts) == 'table', 'LSP options must be a table')
  return opts
end

local function timeout_ms(opts)
  local value = opts.timeout_ms
  if value == nil then return DEFAULT_TIMEOUT_MS end
  assert(type(value) == 'number' and value % 1 == 0, 'timeout_ms must be an integer')
  if value <= 0 then return DEFAULT_TIMEOUT_MS end
  return value
end

local function buffer_number(opts)
  local buf = opts.buf == nil and 0 or opts.buf
  assert(type(buf) == 'number' and buf % 1 == 0, 'buf must be an integer')
  return buf
end

local function supports_method(client, method, buf)
  if type(client.supports_method) ~= 'function' then return false end
  local ok, supported = pcall(client.supports_method, client, method, buf)
  return ok and supported == true
end

local function client_id_less(left, right) return (left.id or math.huge) < (right.id or math.huge) end

---@param opts table
---@param method string
---@return vim.lsp.Client?, string?
local function select_client(opts, method)
  local buf = buffer_number(opts)
  local clients = vim.lsp.get_clients({ bufnr = buf })

  if opts.client_id ~= nil then
    assert(type(opts.client_id) == 'number' and opts.client_id % 1 == 0, 'client_id must be an integer')

    for _, client in ipairs(clients) do
      if client.id == opts.client_id then
        if supports_method(client, method, buf) then return client end
        return nil, ('LSP client %d does not support %s'):format(opts.client_id, method)
      end
    end

    return nil, ('LSP client %d is not attached to buffer %d'):format(opts.client_id, buf)
  end

  local supported = {}
  for _, client in ipairs(clients) do
    if supports_method(client, method, buf) then supported[#supported + 1] = client end
  end
  table.sort(supported, client_id_less)

  local client = supported[1]
  if not client then return nil, ('no LSP client supports %s'):format(method) end
  return client
end

local function uri_for_buffer(buf) return vim.uri_from_bufnr(buf) end

local function cursor_position(opts, client, buf)
  assert(type(opts.cursor) == 'table', 'cursor must be a table')
  local line = opts.cursor.line
  local byte_col = opts.cursor.byte_col
  assert(type(line) == 'number' and line % 1 == 0 and line >= 0, 'cursor.line must be a non-negative integer')
  assert(
    type(byte_col) == 'number' and byte_col % 1 == 0 and byte_col >= 0,
    'cursor.byte_col must be a non-negative integer'
  )

  local text = vim.api.nvim_buf_get_lines(buf, line, line + 1, false)[1] or ''
  local encoding = client.offset_encoding or 'utf-16'
  return {
    line = line,
    character = vim.str_utfindex(text, encoding, math.min(byte_col, #text), false),
  }
end

local function close_timer(timer)
  if not timer then return end
  pcall(timer.stop, timer)
  pcall(timer.close, timer)
end

---@param callback fun(err?: any, result?: any)
---@param client vim.lsp.Client
---@param method string
---@param params table
---@param buf integer
---@param timeout integer
---@param transform fun(result: any): any
---@return fun()
local function start_request(callback, client, method, params, buf, timeout, transform)
  local scope = Async.scope()
  local timer = assert(vim.uv.new_timer(), 'failed to create LSP request timer')
  local request = scope:begin({ mode = 'parallel' })
  local request_id
  local callback_done = false

  local function dispose_timer() close_timer(timer) end

  local function deliver(err, result)
    if callback_done then return end
    callback_done = true
    callback(err, result)
  end

  local function finish(err, result)
    if not request:finish() then return end
    if err ~= nil then
      deliver(err)
    else
      local ok, transformed = pcall(transform, result)
      if ok then
        deliver(nil, transformed)
      else
        deliver(transformed)
      end
    end
  end

  local function on_timeout()
    if not request:is_current() then return end
    if request:cancel() then deliver(('LSP request timed out after %d ms'):format(timeout)) end
  end

  request:set_cancel(function()
    if request_id ~= nil then pcall(client.cancel_request, client, request_id) end
  end)
  request:set_disposer(dispose_timer)
  timer:start(timeout, 0, vim.schedule_wrap(on_timeout))

  local ok, success, id = pcall(
    client.request,
    client,
    method,
    params,
    function(err, result) finish(err, result) end,
    buf
  )

  if not ok then
    finish(success)
  elseif not success or id == nil then
    finish(('LSP client failed to start %s'):format(method))
  else
    request_id = id
  end

  return function() request:cancel() end
end

local function run(callback, opts, client, method, params, transform)
  assert(type(callback) == 'function', 'callback must be a function')
  opts = normalize_options(opts)
  local delivered = false
  local function once(err, result)
    if delivered then return end
    delivered = true
    callback(err, result)
  end

  local buf = buffer_number(opts)
  local timeout = timeout_ms(opts)
  local request_ok, cancel_or_error = pcall(start_request, once, client, method, params, buf, timeout, transform)
  if not request_ok then
    once(cancel_or_error)
    return function() end
  end
  return cancel_or_error
end

local function location_key(location)
  local range = location.range or {}
  local start = range.start or {}
  local finish = range['end'] or {}
  return table.concat({
    tostring(location.uri),
    tostring(start.line),
    tostring(start.character),
    tostring(finish.line),
    tostring(finish.character),
  }, '\0')
end

local function normalize_locations(result)
  local locations = {}
  local seen = {}
  if result == nil then return locations end

  local entries
  if type(result) ~= 'table' then
    return locations
  elseif result.uri ~= nil or result.targetUri ~= nil then
    entries = { result }
  else
    entries = result
  end

  for _, location in ipairs(entries) do
    if type(location) == 'table' then
      local uri
      local range
      if location.targetUri ~= nil then
        uri = location.targetUri
        range = location.targetSelectionRange or location.targetRange
      else
        uri = location.uri
        range = location.range
      end

      if type(uri) == 'string' and type(range) == 'table' then
        local normalized = { uri = uri, range = range }
        local key = location_key(normalized)
        if not seen[key] then
          seen[key] = true
          locations[#locations + 1] = normalized
        end
      end
    end
  end
  return locations
end

---@param opts VVSymbolsLspLocationsOpts
---@param callback fun(err?: any, result?: VVSymbolsLspLocationsResult)
---@return fun() cancel
function M.locations(opts, callback)
  opts = normalize_options(opts)
  assert(type(callback) == 'function', 'callback must be a function')
  local buf = buffer_number(opts)
  assert(type(opts.method) == 'string', 'method must be a string')
  local method = LOCATION_METHODS[opts.method]
  assert(method, ('unsupported LSP location method: %s'):format(opts.method))

  local client, err = select_client(opts, method)
  if not client then
    callback(err)
    return function() end
  end

  local params = {
    textDocument = { uri = uri_for_buffer(buf) },
    position = cursor_position(opts, client, buf),
  }
  if opts.method == 'references' then params.context = { includeDeclaration = opts.include_declaration == true } end

  return run(callback, opts, client, method, params, function(result)
    local locations = normalize_locations(result)
    return {
      locations = locations,
      count = #locations,
      encoding = client.offset_encoding or 'utf-16',
      client_id = client.id,
    }
  end)
end

---@param opts? VVSymbolsLspSymbolsOpts
---@param callback fun(err?: any, result?: VVSymbolsLspSymbolsResult)
---@return fun() cancel
function M.symbols(opts, callback)
  opts = normalize_options(opts)
  local buf = buffer_number(opts)
  local client, err = select_client(opts, DOCUMENT_SYMBOL_METHOD)
  if not client then
    assert(type(callback) == 'function', 'callback must be a function')
    callback(err)
    return function() end
  end

  local params = { textDocument = { uri = uri_for_buffer(buf) } }
  return run(
    callback,
    opts,
    client,
    DOCUMENT_SYMBOL_METHOD,
    params,
    function(result)
      return {
        symbols = result or {},
        client_id = client.id,
        encoding = client.offset_encoding,
      }
    end
  )
end

---@param opts VVSymbolsLspReferencesOpts
---@param callback fun(err?: any, result?: VVSymbolsLspReferencesResult)
---@return fun() cancel
function M.references(opts, callback)
  opts = normalize_options(opts)
  local buf = buffer_number(opts)
  assert(type(opts.uri) == 'string', 'uri must be a string')
  assert(type(opts.position) == 'table', 'position must be an LSP position')

  local client, err = select_client(opts, REFERENCES_METHOD)
  if not client then
    assert(type(callback) == 'function', 'callback must be a function')
    callback(err)
    return function() end
  end

  local params = {
    textDocument = { uri = opts.uri },
    position = opts.position,
    context = { includeDeclaration = opts.include_declaration == true },
  }
  return run(callback, opts, client, REFERENCES_METHOD, params, function(result)
    local locations = normalize_locations(result)
    return {
      locations = locations,
      count = #locations,
      encoding = client.offset_encoding,
    }
  end)
end

---@class VVSymbolsLspLocationsOpts
---@field buf? integer Buffer handle, or 0 for the current buffer. @default 0
---@field method 'references'|'definition'|'declaration'|'implementation'|'type_definition' LSP location request kind.
---@field cursor {line:integer,byte_col:integer} 0-based buffer line and byte column at the query position.
---@field timeout_ms? integer Request timeout in milliseconds. @default 1000
---@field include_declaration? boolean Include the declaration for a references request. @default false
---@field client_id? integer Prefer this client id. @default nil

---@class VVSymbolsLspLocationsResult
---@field locations lsp.Location[] Normalized and deduplicated locations.
---@field count integer Number of locations.
---@field encoding string Selected client's offset encoding.
---@field client_id integer Selected client id.

---@class VVSymbolsLspSymbolsOpts
---@field buf? integer Buffer handle, or 0 for the current buffer. @default 0
---@field timeout_ms? integer Request timeout in milliseconds. @default 1000
---@field client_id? integer Prefer this client id. @default nil

---@class VVSymbolsLspSymbolsResult
---@field symbols lsp.DocumentSymbol[]|lsp.SymbolInformation[]
---@field client_id integer
---@field encoding string

---@class VVSymbolsLspReferencesOpts
---@field buf? integer Buffer handle, or 0 for the current buffer. @default 0
---@field client_id? integer Prefer this client id. @default nil
---@field uri string Document URI sent to the selected client.
---@field position lsp.Position Position already encoded for the selected client.
---@field include_declaration? boolean Whether the declaration is included. @default false
---@field timeout_ms? integer Request timeout in milliseconds. @default 1000

---@class VVSymbolsLspReferencesResult
---@field locations lsp.Location[]
---@field count integer
---@field encoding string

return M
