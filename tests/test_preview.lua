-- 引用侧栏的真实窗口契约：跨文件预览、取消恢复、确认跳转与迟到预览
local root = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
vim.opt.rtp:prepend(root)
vim.opt.rtp:prepend(root .. '/../vv-utils.nvim')
vim.o.columns, vim.o.lines = 160, 40
local source, source_win = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
vim.api.nvim_buf_set_name(source, '/tmp/vv-symbols-preview-source.lua')
local lines = {}
for i = 1, 100 do
  lines[i] = 'local value = ' .. i
end
vim.api.nvim_buf_set_lines(source, 0, -1, false, lines)
vim.api.nvim_win_set_cursor(source_win, { 60, 6 })
vim.fn.winrestview({ topline = 50 })
local original = vim.fn.winsaveview()
local target = vim.api.nvim_create_buf(true, false)
vim.api.nvim_buf_set_name(target, '/tmp/vv-symbols-preview-target.lua')
vim.api.nvim_buf_set_lines(target, 0, -1, false, { 'local x = 1', 'local café = value', 'return café' })
local range = { start = { line = 1, character = 6 }, ['end'] = { line = 1, character = 10 } }
local roots = require('vv-symbols.locations').build({
  items = {
    { uri = vim.uri_from_bufnr(target), range = range, encoding = 'utf-16' },
  },
})
local function key(keys) vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), 'xt', false) end
local function open()
  local view = require('vv-symbols.panel').new({
    config = require('vv-symbols.config').normalize(),
    on_refresh = function() end,
    on_close = function() end,
    on_references = function() end,
  })
  view:show({ buf = source, mode = 'references', nodes = roots, results = {}, status = 'ready' })
  view:open()
  local panel_win = view.tree.win
  vim.api.nvim_win_set_cursor(panel_win, { view.tree.node_lines[roots[1].children[1].id], 0 })
  vim.api.nvim_exec_autocmds('CursorMoved', { buffer = view.tree.buf })
  assert(
    vim.wait(
      400,
      function()
        return vim.api.nvim_win_get_buf(source_win) == target
          and vim.deep_equal(vim.api.nvim_win_get_cursor(source_win), { 2, 6 })
      end,
      5
    ),
    'moving over a reference must preview another file in the source window'
  )
  assert(vim.api.nvim_get_current_win() == panel_win, 'preview must retain sidebar focus')
  return view
end
for _, cancel in ipairs({ 'q', '<Esc>' }) do
  local view = open()
  key(cancel)
  assert(not view:is_open() and vim.api.nvim_get_current_win() == source_win)
  assert(vim.api.nvim_win_get_buf(source_win) == source, 'cancel restores the original file')
  local restored = vim.fn.winsaveview()
  assert(
    restored.lnum == original.lnum and restored.col == original.col and restored.topline == original.topline,
    'cancel restores original cursor and viewport'
  )
end
local view = open()
key('<CR>')
assert(view:is_open() and vim.api.nvim_get_current_win() == source_win, 'Enter enters source and keeps sidebar')
assert(vim.api.nvim_win_get_buf(source_win) == target)
vim.wait(120, function() return false end)
assert(vim.api.nvim_win_get_buf(source_win) == target, 'queued preview cannot undo Enter')
vim.api.nvim_set_current_win(view.tree.win)
key('q')
assert(vim.api.nvim_win_get_buf(source_win) == target, 'closing after Enter preserves the confirmed location')
vim.api.nvim_win_set_buf(source_win, source)
vim.fn.winrestview(original)
view = open()
key('gf')
assert(not view:is_open() and vim.api.nvim_get_current_win() == source_win, 'gf enters source and closes sidebar')
assert(
  vim.api.nvim_win_get_buf(source_win) == target and vim.deep_equal(vim.api.nvim_win_get_cursor(source_win), { 2, 6 })
)
print('PASS cross-file preview, q/Esc restore, Enter commit and gf close')
