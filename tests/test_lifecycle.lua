-- 控制器契约：切源物理取消、迟到结果丢弃、编辑清理虚拟行、关闭不重建面板
local root = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
vim.opt.rtp:prepend(root)
vim.opt.rtp:prepend(root .. '/../vv-utils.nvim')
local requests, cancelled = {}, 0
package.loaded['vv-symbols.lsp'] = {
  symbols = function(opts, cb)
    requests[#requests + 1] = { buf = opts.buf, cb = cb }
    return function() cancelled = cancelled + 1 end
  end,
  references = function(_, cb)
    cb(nil, { count = 0, locations = {}, encoding = 'utf-16' })
    return function() end
  end,
}
local plugin = require('vv-symbols')
plugin.setup({ lens = { enabled = false, scope = 'all' }, timing = { debounce_ms = 10 } })
local a = vim.api.nvim_get_current_buf()
vim.api.nvim_buf_set_name(a, '/tmp/vv-symbols-lifecycle-a.lua')
vim.api.nvim_buf_set_lines(a, 0, -1, false, { 'local function old() end' })
plugin.open()
local panel_buf = vim.api.nvim_get_current_buf()
assert(#requests == 1)
local b = vim.api.nvim_create_buf(true, false)
vim.api.nvim_buf_set_name(b, '/tmp/vv-symbols-lifecycle-b.lua')
vim.api.nvim_buf_set_lines(b, 0, -1, false, { 'local function new() end' })
plugin.open({ buf = b })
assert(cancelled >= 1, '切源必须物理取消旧请求')
local function reply(req, name)
  local range = { start = { line = 0, character = 0 }, ['end'] = { line = 0, character = 23 } }
  req.cb(nil, {
    client_id = 1,
    encoding = 'utf-16',
    symbols = {
      { name = name, kind = 12, range = range, selectionRange = range },
    },
  })
end
reply(requests[1], 'old')
reply(requests[#requests], 'new')
vim.wait(100, function() return false end)
local lines = table.concat(vim.api.nvim_buf_get_lines(panel_buf, 0, -1, false), '\n')
assert(lines:find('new', 1, true) and not lines:find('old', 1, true), lines)
plugin.enable_lens()
reply(requests[#requests], 'new')
local namespace = vim.api.nvim_create_namespace('vv-symbols.lens')
assert(
  vim.wait(100, function() return #vim.api.nvim_buf_get_extmarks(b, namespace, 0, -1, {}) == 1 end),
  '当前成功结果应渲染 lens'
)
vim.api.nvim_buf_set_lines(b, 0, -1, false, { 'local function changed() end' })
vim.api.nvim_exec_autocmds('TextChanged', { buffer = b })
assert(#vim.api.nvim_buf_get_extmarks(b, namespace, 0, -1, {}) == 0, '编辑应立即失效旧 lens')
plugin.disable_lens()
plugin.refresh()
local pending = requests[#requests]
plugin.close()
reply(pending, 'late')
vim.wait(60, function() return false end)
assert(not plugin.is_open(), '迟到结果不得重新打开面板')
assert(not vim.api.nvim_buf_is_valid(panel_buf), '面板已被销毁')
plugin.disable()
plugin.disable()
print('PASS 切源取消与迟到回调')
