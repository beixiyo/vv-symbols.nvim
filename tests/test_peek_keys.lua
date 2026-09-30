-- peek 快捷键契约：trigger 随 LSP attach 注册为 buffer-local、auto 方法按语义 token 选择、
-- disable 只移除自己注册的键、peek.keys 改键与禁用生效
local root = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
vim.opt.rtp:prepend(root)
vim.opt.rtp:prepend(root .. '/../vv-utils.nvim')

local requests = {}
package.loaded['vv-symbols.lsp'] = {
  symbols = function() return function() end end,
  references = function() return function() end end,
  locations = function(opts, callback)
    requests[#requests + 1] = { method = opts.method, callback = callback }
    return function() end
  end,
}

local plugin = require('vv-symbols')

local function file_buf(name)
  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_name(buf, '/tmp/vv-symbols-peek-keys-' .. name .. '.lua')
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'local iface = 1' })
  return buf
end

local function attach(buf) vim.api.nvim_exec_autocmds('LspAttach', { buffer = buf, data = { client_id = 1 } }) end

local function mapping(buf, lhs)
  return vim.api.nvim_buf_call(buf, function() return vim.fn.maparg(lhs, 'n', false, true) end)
end

local function press(buf, keys)
  vim.api.nvim_set_current_buf(buf)
  vim.api.nvim_win_set_cursor(0, { 1, 6 })
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), 'xt', false)
end

-- 默认：LSP attach 的文件 buffer 注册 buffer-local gp，nofile buffer 不注册
plugin.setup({ lens = { enabled = false } })
local a = file_buf('a')
attach(a)
assert(mapping(a, 'gp').buffer == 1, 'LSP attach 后文件 buffer 应有 buffer-local gp')
local scratch = vim.api.nvim_create_buf(false, true)
vim.bo[scratch].buftype = 'nofile'
attach(scratch)
assert(vim.tbl_isempty(mapping(scratch, 'gp')), 'nofile buffer 不应注册 gp')

-- auto：无语义 token 查 implementation，类型 token 上查 definition
press(a, 'gp')
assert(requests[#requests].method == 'implementation', '无语义 token 时 gp 应查 implementation')
local original_get_at_pos = vim.lsp.semantic_tokens.get_at_pos
vim.lsp.semantic_tokens.get_at_pos = function() return { { type = 'interface' } } end
press(a, 'gp')
vim.lsp.semantic_tokens.get_at_pos = original_get_at_pos
assert(requests[#requests].method == 'definition', '类型名上 gp 应查 definition 看声明体')

-- disable 移除自己注册的 gp，但不删调用方后来覆盖的同名键
local b = file_buf('b')
attach(b)
vim.keymap.set('n', 'gp', '<Nop>', { buffer = b, desc = 'user override' })
plugin.disable()
assert(vim.tbl_isempty(mapping(a, 'gp')), 'disable 应移除插件注册的 gp')
assert(mapping(b, 'gp').desc == 'user override', 'disable 不得删除调用方覆盖的 gp')

-- 改键与禁用：trigger 改为 gP；next = false 时浮窗内不注册 ]p
plugin.setup({ lens = { enabled = false }, peek = { keys = { trigger = 'gP', next = false } } })
local c = file_buf('c')
attach(c)
assert(vim.tbl_isempty(mapping(c, 'gp')) and mapping(c, 'gP').buffer == 1, 'trigger 应改为 gP')
press(c, 'gP')
local dir = vim.fn.tempname()
vim.fn.mkdir(dir, 'p')
vim.fn.writefile({ 'local impl = 1' }, dir .. '/impl.lua')
local range = { start = { line = 0, character = 6 }, ['end'] = { line = 0, character = 10 } }
requests[#requests].callback(nil, {
  locations = { { uri = 'file://' .. dir .. '/impl.lua', range = range } },
  count = 1,
  encoding = 'utf-16',
  client_id = 1,
})
local float = vim.api.nvim_get_current_buf()
assert(float ~= c, 'peek 浮窗应打开并持有焦点')
assert(vim.tbl_isempty(mapping(float, ']p')), 'next = false 时浮窗内不应注册 ]p')
assert(not vim.tbl_isempty(mapping(float, '[p')), '未禁用的 prev 仍应注册 [p')
plugin.disable()

-- keys = false：全部禁用，不注册触发键
plugin.setup({ lens = { enabled = false }, peek = { keys = false } })
local d = file_buf('d')
attach(d)
assert(vim.tbl_isempty(mapping(d, 'gp')), 'keys = false 时不应注册任何触发键')
plugin.disable()

print('test_peek_keys: all assertions passed')
