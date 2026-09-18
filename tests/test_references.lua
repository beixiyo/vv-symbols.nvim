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

assert(vim.wait(100, function() return #requests == 2 end, 5), '初始泵送应按并发上限发起请求')
assert(max_active == 2, '活跃请求数不得超过并发上限')
assert(
  requests[1].opts.include_declaration == false and requests[1].opts.timeout_ms == 3000,
  'LSP 边界应收到归一化默认值'
)

resolve(1, nil, {
  locations = { { uri = 'file:///use.lua' }, { uri = 'file:///use2.lua' } },
  count = 2,
  encoding = 'utf-16',
})
assert(vim.wait(100, function() return #requests == 3 end, 5), '完成的请求应继续泵送队列')
assert(max_active == 2, '队列泵送须维持并发上限')

resolve(2, 'server failed')
resolve(3, nil, { locations = {}, count = 0, encoding = 'utf-8' })
assert(
  vim.wait(100, function() return #updates > 0 end, 5),
  '状态变化应经调度回调发布'
)
local final = updates[#updates]
assert(final['fn-1'].status == 'ready' and final['fn-1'].count == 2, 'ready 结果应保留位置计数')
assert(
  final['fn-2'].status == 'error' and final['fn-2'].count == nil,
  '错误不得表示为零引用'
)
assert(
  final['fn-3'].status == 'ready' and final['fn-3'].count == 0,
  '真实的空响应应保持零引用'
)
assert(final['fn-4'].status == 'skipped', '超出 max_symbols 的符号应被跳过')
assert(final.variable == nil, '不可调用符号不得纳入统计')

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
assert(#requests == 4, '畸形结果样例应产生一次请求')
resolve(4, nil, { locations = {}, encoding = 'utf-8' })
assert(
  vim.wait(100, function() return #malformed_updates > 0 end, 5),
  '畸形结果也应完成请求'
)
local malformed = malformed_updates[#malformed_updates].malformed
assert(
  malformed.status == 'error' and malformed.count == nil,
  '缺失 count 的结果不得渲染成零引用'
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
assert(#requests == 5, '新一轮应产生一次请求')
late_cancel()
requests[5].callback(nil, { locations = { {} }, count = 1, encoding = 'utf-8' })
assert(
  vim.wait(100, function() return physical_cancels == 1 end, 5),
  '取消应物理取消在途 LSP 请求'
)
vim.wait(50)
assert(late_updates == 0, '已取消的轮次必须忽略调度与迟到回调')

vim.cmd('qa!')
