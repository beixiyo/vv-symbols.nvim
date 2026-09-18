-- 公共 API 回归：去重后的单目标直接跳转，不打开加载分屏
local root = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
vim.opt.rtp:prepend(root)
vim.opt.rtp:prepend(root .. '/../vv-utils.nvim')
local requests = {}
package.loaded['vv-symbols.lsp'] = {
  symbols = function() error('location queries do not require symbols') end,
  locations = function(opts, callback)
    requests[#requests + 1] = { opts = opts, callback = callback }
    return function() end
  end,
}
local plugin = require('vv-symbols')
plugin.setup({ lens = { enabled = false } })
local source, win = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
vim.api.nvim_buf_set_name(source, '/tmp/vv-single-source.ts')
vim.api.nvim_buf_set_lines(source, 0, -1, false, { 'target()' })
local target = vim.api.nvim_create_buf(true, false)
vim.api.nvim_buf_set_name(target, '/tmp/vv-single-target.ts')
vim.api.nvim_buf_set_lines(target, 0, -1, false, { '/* 中文 */ target()' })
local location = {
  uri = vim.uri_from_bufnr(target),
  range = { start = { line = 0, character = 9 }, ['end'] = { line = 0, character = 15 } },
}
for _, method in ipairs({ 'definition', 'references', 'implementation', 'declaration', 'type_definition' }) do
  vim.api.nvim_win_set_buf(win, source)
  vim.api.nvim_win_set_cursor(win, { 1, 0 })
  plugin.locations({ method = method })
  assert(not plugin.is_open() and #vim.api.nvim_list_wins() == 1, '查询进行中不得打开加载分屏')
  requests[#requests].callback(nil, { locations = { location, location }, encoding = 'utf-16' })
  assert(not plugin.is_open(), '重复位置应视为一个目标')
  assert(vim.api.nvim_get_current_buf() == target, method .. ' 必须跳转到目标文件')
  assert(vim.api.nvim_win_get_cursor(win)[2] == 13, 'UTF-16 目标列必须换算为字节列')
  local ns = vim.api.nvim_get_namespaces()['vv-symbols.locations']
  assert(#vim.api.nvim_buf_get_extmarks(source, ns, 0, -1, {}) == 0, '直接跳转应释放源码标记')
end
vim.api.nvim_win_set_buf(win, source)
plugin.references()
local cancelled = requests[#requests]
plugin.close()
cancelled.callback(nil, { locations = { location }, encoding = 'utf-16' })
assert(vim.api.nvim_get_current_buf() == source and not plugin.is_open(), '关闭应取消延迟的单结果跳转')

plugin.references()
requests[#requests].callback(nil, {
  locations = {
    location,
    {
      uri = vim.uri_from_bufnr(source),
      range = { start = { line = 0, character = 0 }, ['end'] = { line = 0, character = 6 } },
    },
  },
  encoding = 'utf-16',
})
assert(plugin.is_open(), '多目标应打开结果列表')
plugin.close()
vim.api.nvim_set_current_win(win)
plugin.references()
requests[#requests].callback(nil, { locations = {}, encoding = 'utf-16' })
assert(not plugin.is_open(), '空结果不得创建侧栏')
plugin.close()
plugin.disable()
-- 空的成功响应对所有 LSP location 查询同样保持静默
local notify = vim.notify
local notifications = 0
vim.notify = function() notifications = notifications + 1 end
plugin.setup({ lens = { enabled = false } })
for _, method in ipairs({ 'references', 'implementation', 'definition', 'declaration', 'type_definition' }) do
  plugin.locations({ buf = source, method = method, cursor = { line = 0, byte_col = 0 } })
  requests[#requests].callback(nil, { locations = {}, encoding = 'utf-16' })
  assert(not plugin.is_open(), method .. ' 的空结果不得打开侧栏')
end
vim.notify = notify
assert(notifications == 0, 'LSP 空结果不得发出通知')
plugin.disable()
print('PASS 单结果跳转、UTF-16、去重、取消与多/空结果列表')
