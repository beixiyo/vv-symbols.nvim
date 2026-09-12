-- Public API regression: one deduplicated target jumps without a loading split.
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
  assert(not plugin.is_open() and #vim.api.nvim_list_wins() == 1, 'pending query must not open a loading split')
  requests[#requests].callback(nil, { locations = { location, location }, encoding = 'utf-16' })
  assert(not plugin.is_open(), 'duplicate locations must count as one target')
  assert(vim.api.nvim_get_current_buf() == target, method .. ' must jump to the target file')
  assert(vim.api.nvim_win_get_cursor(win)[2] == 13, 'UTF-16 target columns must convert to bytes')
  local ns = vim.api.nvim_get_namespaces()['vv-symbols.locations']
  assert(#vim.api.nvim_buf_get_extmarks(source, ns, 0, -1, {}) == 0, 'direct jump must release source tracking')
end
vim.api.nvim_win_set_buf(win, source)
plugin.references()
local cancelled = requests[#requests]
plugin.close()
cancelled.callback(nil, { locations = { location }, encoding = 'utf-16' })
assert(vim.api.nvim_get_current_buf() == source and not plugin.is_open(), 'close must cancel a deferred single jump')

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
assert(plugin.is_open(), 'multiple targets must open the result list')
plugin.close()
vim.api.nvim_set_current_win(win)
plugin.references()
requests[#requests].callback(nil, { locations = {}, encoding = 'utf-16' })
assert(not plugin.is_open(), 'empty results must not create a sidebar')
plugin.close()
plugin.disable()
-- Empty successful responses must be equally silent for every LSP location key.
local notify = vim.notify
local notifications = 0
vim.notify = function() notifications = notifications + 1 end
plugin.setup({ lens = { enabled = false } })
for _, method in ipairs({ 'references', 'implementation', 'definition', 'declaration', 'type_definition' }) do
  plugin.locations({ buf = source, method = method, cursor = { line = 0, byte_col = 0 } })
  requests[#requests].callback(nil, { locations = {}, encoding = 'utf-16' })
  assert(not plugin.is_open(), 'empty ' .. method .. ' must not open a sidebar')
end
vim.notify = notify
assert(notifications == 0, 'empty LSP results must not emit notifications')
plugin.disable()
print('PASS single-result jumps, UTF-16, deduplication, cancellation and multiple/empty lists')
