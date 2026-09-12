-- Behaviour tests for vv-symbols LSP requests.

local source = debug.getinfo(1, 'S').source:sub(2)
local root = vim.fn.fnamemodify(source, ':p:h:h')
local utils_root = vim.fn.fnamemodify(root, ':h') .. '/vv-utils.nvim'
vim.opt.runtimepath:prepend(root)
vim.opt.runtimepath:prepend(utils_root)

local Lsp = require('vv-symbols.lsp')

local function wait_for(predicate, timeout)
  assert(vim.wait(timeout or 200, predicate, 5), 'timed out waiting for async callback')
end

local function with_clients(clients, callback)
  local old_get_clients = vim.lsp.get_clients
  vim.lsp.get_clients = function() return clients end
  local ok, err = pcall(callback)
  vim.lsp.get_clients = old_get_clients
  assert(ok, err)
end

local function client_fixture(id, methods, response)
  local client = {
    id = id,
    offset_encoding = 'utf-16',
    requests = {},
    cancelled = {},
  }
  function client:supports_method(method) return methods[method] == true end
  function client:request(method, params, handler)
    self.requests[#self.requests + 1] = { method = method, params = params, handler = handler }
    if response then response(self, method, params, handler) end
    return true, #self.requests
  end
  function client:cancel_request(request_id) self.cancelled[#self.cancelled + 1] = request_id end
  return client
end

do
  local first = client_fixture(9, { ['textDocument/documentSymbol'] = true })
  local second = client_fixture(3, { ['textDocument/documentSymbol'] = true })
  with_clients({ first, second }, function()
    local result
    Lsp.symbols({ buf = 0, timeout_ms = 100 }, function(err, value) result = { err = err, value = value } end)
    assert(#second.requests == 1 and #first.requests == 0, 'symbols must choose the lowest client id')
    second.requests[1].handler(nil, { { name = 'root' } })
    wait_for(function() return result ~= nil end)
    assert(result.err == nil and result.value.client_id == 3)
    assert(result.value.encoding == 'utf-16' and result.value.symbols[1].name == 'root')
  end)
end

do
  local selected = client_fixture(7, { ['textDocument/documentSymbol'] = true })
  local other = client_fixture(1, { ['textDocument/documentSymbol'] = true })
  with_clients({ selected, other }, function()
    local result
    Lsp.symbols({ buf = 0, client_id = 7 }, function(err, value) result = { err = err, value = value } end)
    assert(#selected.requests == 1 and #other.requests == 0, 'explicit client_id must take priority')
    selected.requests[1].handler(nil, nil)
    wait_for(function() return result ~= nil end)
    assert(result.err == nil and #result.value.symbols == 0, 'nil symbols response must be an empty list')
  end)
end

do
  local client = client_fixture(5, { ['textDocument/references'] = true })
  with_clients({ client }, function()
    local result
    Lsp.references({
      buf = 0,
      uri = 'file:///main.lua',
      position = { line = 2, character = 4 },
      include_declaration = true,
      timeout_ms = 100,
    }, function(err, value) result = { err = err, value = value } end)
    assert(client.requests[1].params.position.line == 2)
    assert(client.requests[1].params.context.includeDeclaration == true)
    local location = {
      uri = 'file:///main.lua',
      range = { start = { line = 1, character = 2 }, ['end'] = { line = 1, character = 5 } },
    }
    client.requests[1].handler(
      nil,
      { location, vim.deepcopy(location), { uri = 'file:///other.lua', range = location.range } }
    )
    wait_for(function() return result ~= nil end)
    assert(
      result.err == nil and result.value.count == 2 and #result.value.locations == 2,
      'duplicate locations must be removed'
    )
  end)
end

do
  local client = client_fixture(4, { ['textDocument/references'] = true })
  with_clients({ client }, function()
    local result
    local cancel = Lsp.references(
      { buf = 0, uri = 'file:///cancel.lua', position = { line = 0, character = 0 }, timeout_ms = 100 },
      function(err, value) result = { err = err, value = value } end
    )
    cancel()
    assert(#client.cancelled == 1 and client.cancelled[1] == 1, 'cancel must physically cancel the request')
    client.requests[1].handler(nil, {})
    vim.wait(30, function() return false end, 5)
    assert(result == nil, 'late response after cancel must be discarded')
  end)
end

do
  local client = client_fixture(6, { ['textDocument/references'] = true })
  with_clients({ client }, function()
    local result
    local api_ok
    local api_error
    Lsp.references(
      { buf = 0, uri = 'file:///timeout.lua', position = { line = 0, character = 0 }, timeout_ms = 10 },
      function(err, value)
        api_ok, api_error = pcall(vim.api.nvim_buf_set_var, 0, 'vv_symbols_timeout_probe', true)
        result = { err = err, value = value }
      end
    )
    wait_for(function() return result ~= nil end, 200)
    assert(result.err and result.value == nil, 'timeout must report an error without a zero result')
    assert(#client.cancelled == 1, 'timeout must physically cancel the request')
    assert(api_ok, api_error)
  end)
end

do
  local client = client_fixture(
    8,
    { ['textDocument/references'] = true },
    function(_, _, _, handler) handler(nil, {}) end
  )
  with_clients({ client }, function()
    local calls = 0
    local result
    Lsp.references(
      { buf = 0, uri = 'file:///sync.lua', position = { line = 0, character = 0 }, timeout_ms = 0 },
      function(err, value)
        calls = calls + 1
        result = { err = err, value = value }
      end
    )
    assert(calls == 1 and result.err == nil and result.value.count == 0, 'synchronous responses must callback once')
    assert(#client.cancelled == 0, 'synchronous completion must not cancel a completed request')
  end)
end

do
  local client = client_fixture(10, { ['textDocument/documentSymbol'] = true })
  function client:request() error('request fixture failed') end
  with_clients({ client }, function()
    local calls = 0
    local error_value
    Lsp.symbols({ buf = 0, timeout_ms = 10 }, function(err)
      calls = calls + 1
      error_value = err
    end)
    assert(calls == 1 and error_value, 'request exceptions must callback exactly once')
  end)
end

do
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { '前😀value()' })
  local client = client_fixture(11, {
    ['textDocument/references'] = true,
    ['textDocument/definition'] = true,
    ['textDocument/declaration'] = true,
    ['textDocument/implementation'] = true,
    ['textDocument/typeDefinition'] = true,
  }, function(_, method, _, handler)
    if method == 'textDocument/definition' then
      handler(nil, {
        uri = 'file:///definition.lua',
        range = { start = { line = 1, character = 2 }, ['end'] = { line = 1, character = 5 } },
      })
    else
      handler(nil, {})
    end
  end)

  with_clients({ client }, function()
    local result
    Lsp.locations(
      { buf = buf, method = 'definition', cursor = { line = 0, byte_col = 7 } },
      function(err, value) result = { err = err, value = value } end
    )
    assert(result.err == nil and result.value.client_id == 11)
    assert(result.value.encoding == 'utf-16' and result.value.count == 1)
    assert(result.value.locations[1].uri == 'file:///definition.lua')
    assert(client.requests[1].params.position.line == 0)
    assert(client.requests[1].params.position.character == 3, 'byte column must convert to UTF-16 units')
  end)

  local methods = {
    references = 'textDocument/references',
    definition = 'textDocument/definition',
    declaration = 'textDocument/declaration',
    implementation = 'textDocument/implementation',
    type_definition = 'textDocument/typeDefinition',
  }
  for kind, protocol_method in pairs(methods) do
    local routed = client_fixture(20, { [protocol_method] = true }, function(_, _, _, handler) handler(nil, {}) end)
    with_clients({ routed }, function()
      Lsp.locations(
        { buf = buf, method = kind, cursor = { line = 0, byte_col = 0 } },
        function(err) assert(err == nil) end
      )
      assert(routed.requests[1].method == protocol_method, kind .. ' must use its LSP method')
    end)
  end
end

do
  local client = client_fixture(12, { ['textDocument/declaration'] = true }, function(_, _, _, handler)
    local range = { start = { line = 2, character = 1 }, ['end'] = { line = 2, character = 4 } }
    handler(nil, {
      { targetUri = 'file:///declaration.lua', targetRange = range, targetSelectionRange = range },
      {
        targetUri = 'file:///declaration.lua',
        targetRange = { start = { line = 2, character = 1 }, ['end'] = { line = 2, character = 8 } },
        targetSelectionRange = range,
      },
    })
  end)
  with_clients({ client }, function()
    local result
    Lsp.locations(
      { buf = 0, method = 'declaration', cursor = { line = 0, byte_col = 0 } },
      function(err, value) result = { err = err, value = value } end
    )
    wait_for(function() return result ~= nil end)
    assert(result.err == nil and result.value.count == 1 and #result.value.locations == 1)
    assert(result.value.locations[1].uri == 'file:///declaration.lua')
    assert(result.value.locations[1].range['end'].character == 4, 'targetSelectionRange must win over targetRange')
  end)
end

do
  local low = client_fixture(3, { ['textDocument/implementation'] = true })
  local high = client_fixture(9, { ['textDocument/implementation'] = true })
  with_clients({ high, low }, function()
    Lsp.locations({ buf = 0, method = 'implementation', cursor = { line = 0, byte_col = 0 } }, function() end)
    assert(#low.requests == 1 and #high.requests == 0, 'locations must choose the lowest supported client id')
  end)
end

do
  local client = client_fixture(13, { ['textDocument/references'] = true })
  with_clients({ client }, function()
    local result
    local cancel = Lsp.locations(
      { buf = 0, method = 'references', cursor = { line = 0, byte_col = 0 }, timeout_ms = 100 },
      function(err, value) result = { err = err, value = value } end
    )
    cancel()
    assert(#client.cancelled == 1 and client.cancelled[1] == 1)
    client.requests[1].handler(nil, {})
    vim.wait(30, function() return false end, 5)
    assert(result == nil, 'late location responses after cancellation must be discarded')
  end)
end

print('test_lsp.lua: ok')
