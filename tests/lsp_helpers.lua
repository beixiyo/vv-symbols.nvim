-- 单客户端请求场景共用的 fixture；此文件不参与测试收集
local M = {}

function M.wait_for(predicate, timeout)
  assert(vim.wait(timeout or 200, predicate, 5), '等待异步回调超时')
end

function M.with_clients(clients, callback)
  local old_get_clients = vim.lsp.get_clients
  vim.lsp.get_clients = function() return clients end
  local ok, err = pcall(callback)
  vim.lsp.get_clients = old_get_clients
  assert(ok, err)
end

function M.client_fixture(id, methods, response)
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

return M
