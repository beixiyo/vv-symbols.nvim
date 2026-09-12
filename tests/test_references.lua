-- references 调度回归：headless nvim -u NONE -l tests/test_references.lua

local source = debug.getinfo(1, 'S').source:sub(2)
local tests_dir = vim.fn.fnamemodify(source, ':p:h')
local root = vim.fn.fnamemodify(tests_dir, ':h')
local vendors = vim.fn.fnamemodify(root, ':h')
vim.opt.runtimepath:prepend(root)
vim.opt.runtimepath:prepend(vendors .. '/vv-utils.nvim')

local requests = {}
local active = 0
local max_active = 0
local physical_cancels = 0

package.preload['vv-symbols.model'] = function()
  return { flatten = function(nodes) return nodes end }
end

package.preload['vv-symbols.lsp'] = function()
  return {
    references = function(opts, callback)
      requests[#requests + 1] = { opts = opts, callback = callback }
      active = active + 1
      max_active = math.max(max_active, active)
      local entry = requests[#requests]
      return function()
        if not entry.cancelled then
          entry.cancelled = true
          physical_cancels = physical_cancels + 1
          active = active - 1
        end
      end
    end,
  }
end

local function resolve(index, err, response)
  local entry = requests[index]
  if not entry.cancelled then active = active - 1 end
  entry.callback(err, response)
end

local References = require('vv-symbols.references')
local nodes = {}
for index = 1, 4 do
  nodes[index] = {
    id = 'fn-' .. index,
    is_callable = true,
    uri = 'file:///fixture.lua',
    selection_range = {
      start = { line = index - 1, character = 0 },
      ['end'] = { line = index - 1, character = 1 },
    },
    buf = 1,
  }
end
nodes[5] = { id = 'variable', is_callable = false, buf = 1 }

local updates = {}
local cancel = References.start({
  buf = 1,
  nodes = nodes,
  concurrency = 2,
  max_symbols = 3,
  on_update = function(snapshot) updates[#updates + 1] = snapshot end,
})

assert(vim.wait(100, function() return #requests == 2 end, 5), 'initial pump should start up to concurrency requests')
assert(max_active == 2, 'active request count must respect concurrency')
assert(
  requests[1].opts.include_declaration == false and requests[1].opts.timeout_ms == 3000,
  'LSP boundary should receive normalized defaults'
)

resolve(1, nil, {
  locations = { { uri = 'file:///use.lua' }, { uri = 'file:///use2.lua' } },
  count = 2,
  encoding = 'utf-16',
})
assert(vim.wait(100, function() return #requests == 3 end, 5), 'a completed request should drain the queue')
assert(max_active == 2, 'queue draining must keep the concurrency cap')

resolve(2, 'server failed')
resolve(3, nil, { locations = {}, count = 0, encoding = 'utf-8' })
assert(
  vim.wait(100, function() return #updates > 0 end, 5),
  'state changes should be published on the scheduled callback'
)
local final = updates[#updates]
assert(final['fn-1'].status == 'ready' and final['fn-1'].count == 2, 'ready result should preserve locations count')
assert(
  final['fn-2'].status == 'error' and final['fn-2'].count == nil,
  'errors must not be represented as zero references'
)
assert(
  final['fn-3'].status == 'ready' and final['fn-3'].count == 0,
  'a real empty response should remain zero references'
)
assert(final['fn-4'].status == 'skipped', 'symbols beyond max_symbols must be skipped')
assert(final.variable == nil, 'non-callable symbols must not be counted')

local malformed_updates = {}
References.start({
  nodes = {
    {
      id = 'malformed',
      is_callable = true,
      buf = 1,
      selection_range = { start = { line = 0, character = 0 }, ['end'] = { line = 0, character = 1 } },
    },
  },
  on_update = function(snapshot) malformed_updates[#malformed_updates + 1] = snapshot end,
})
assert(#requests == 4, 'malformed-result fixture should create one request')
resolve(4, nil, { locations = {}, encoding = 'utf-8' })
assert(
  vim.wait(100, function() return #malformed_updates > 0 end, 5),
  'malformed result should still complete the request'
)
local malformed = malformed_updates[#malformed_updates].malformed
assert(
  malformed.status == 'error' and malformed.count == nil,
  'missing result count must not be rendered as zero references'
)

local late_updates = 0
local late_cancel = References.start({
  nodes = {
    {
      id = 'late',
      is_callable = true,
      buf = 1,
      selection_range = { start = { line = 0, character = 0 }, ['end'] = { line = 0, character = 1 } },
    },
  },
  on_update = function() late_updates = late_updates + 1 end,
})
assert(#requests == 5, 'a new run should create one request')
late_cancel()
requests[5].callback(nil, { locations = { {} }, count = 1, encoding = 'utf-8' })
assert(
  vim.wait(100, function() return physical_cancels == 1 end, 5),
  'cancel should physically cancel an in-flight LSP request'
)
vim.wait(50)
assert(late_updates == 0, 'cancelled runs must ignore scheduled and late callbacks')

vim.cmd('qa!')
