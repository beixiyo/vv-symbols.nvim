local H = dofile('tests/helpers.lua')
local T, child = H.new_set()

T['预览命中高亮与主题覆盖'] = function()
  child.lua_func(function()
    -- VVSymbolsPreview 默认链接 CurSearch：颜色跟随主题；用户预设优先；ColorScheme（hi clear）后重新挂回链接
    local plugin = require('vv-symbols')

    local function link() return vim.api.nvim_get_hl(0, { name = 'VVSymbolsPreview', link = true }).link end
    local function resolved() return vim.api.nvim_get_hl(0, { name = 'VVSymbolsPreview', link = false }) end
    local function settle() vim.wait(50, function() return false end) end

    plugin.setup({ lens = { enabled = false } })
    assert(link() == 'CurSearch', 'setup 后应链接 CurSearch，实际 ' .. vim.inspect(link()))

    -- 主题改 CurSearch 后解析值随之变化（setup 之后加载主题也生效）
    vim.api.nvim_set_hl(0, 'CurSearch', { fg = 0x111111, bg = 0xff9e64, bold = true })
    local hl = resolved()
    assert(hl.fg == 0x111111 and hl.bg == 0xff9e64 and hl.bold == true, '应解析为主题 CurSearch: ' .. vim.inspect(hl))

    -- ColorScheme：hi clear 清掉链接后重新挂回
    vim.cmd('hi clear')
    vim.api.nvim_set_hl(0, 'CurSearch', { bg = 0x61afef })
    vim.api.nvim_exec_autocmds('ColorScheme', {})
    settle()
    assert(link() == 'CurSearch', 'ColorScheme 后应仍链接 CurSearch，实际 ' .. vim.inspect(link()))
    assert(resolved().bg == 0x61afef, 'ColorScheme 后应解析为新主题 CurSearch: ' .. vim.inspect(resolved()))

    -- 用户预先定义的值不被默认链接覆盖
    vim.cmd('hi clear')
    vim.api.nvim_set_hl(0, 'VVSymbolsPreview', { fg = 0x123456 })
    plugin.setup({ lens = { enabled = false } })
    vim.api.nvim_exec_autocmds('ColorScheme', {})
    settle()
    hl = vim.api.nvim_get_hl(0, { name = 'VVSymbolsPreview', link = true })
    assert(hl.link == nil and hl.fg == 0x123456, '用户预设的 VVSymbolsPreview 不得被覆盖: ' .. vim.inspect(hl))
  end)
end

return T
