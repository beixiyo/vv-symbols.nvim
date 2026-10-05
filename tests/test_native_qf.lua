local H = dofile('tests/helpers.lua')
local T, child = H.new_set()

T['原生 quickfix 与 loclist 接管和关闭策略'] = function()
  child.lua_func(function()
    -- 原生 quickfix / loclist 接管：:copen / :lopen 改开 vv-symbols 面板并绑定所属代码窗口；replace_native=false 时保持原生窗口
    local plugin = require('vv-symbols')
    plugin.setup({ lens = { enabled = false } })

    local function native_windows()
      local wins = {}
      for _, info in ipairs(vim.fn.getwininfo()) do
        if info.quickfix == 1 then wins[#wins + 1] = info.winid end
      end
      return wins
    end

    local function panel_text()
      assert(plugin.is_open(), 'vv-symbols 面板应已打开')
      for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        local buf = vim.api.nvim_win_get_buf(win)
        if vim.bo[buf].filetype == 'vv-symbols' then
          return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), '\n')
        end
      end
      error('找不到 vv-symbols 面板窗口')
    end

    local function source(name, text)
      local buf = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_buf_set_name(buf, (vim.env.VV_TEST_TMP .. '/vv-symbols-native-qf-') .. name .. '.lua')
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { text })
      return buf
    end

    local a = source('a', 'local qf_target = 1')
    local b = source('b', 'local loc_target = 2')
    local win_a = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win_a, a)
    vim.cmd('vsplit')
    local win_b = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win_b, b)

    vim.fn.setqflist({ { bufnr = a, lnum = 1, col = 7, text = 'qf_entry_marker' } }, 'r')
    vim.fn.setloclist(win_a, { { bufnr = a, lnum = 1, col = 7, text = 'loc_a_marker' } }, 'r')
    vim.fn.setloclist(win_b, { { bufnr = b, lnum = 1, col = 7, text = 'loc_b_marker' } }, 'r')

    -- quickfix：原生窗口关闭，面板展示 quickfix 内容
    vim.api.nvim_set_current_win(win_a)
    vim.cmd('copen')
    assert(vim.wait(1000, function() return #native_windows() == 0 and plugin.is_open() end), ':copen 后原生窗口应被接管')
    assert(panel_text():find('qf_entry_marker', 1, true), '面板应展示 quickfix 条目')
    assert(vim.api.nvim_win_is_valid(win_a) and vim.api.nvim_win_get_buf(win_a) == a, '所属代码窗口应保持不变')plugin.close()

    -- loclist：绑定 :lopen 所在窗口的位置列表，而不是其他窗口的
    vim.api.nvim_set_current_win(win_b)
    vim.cmd('lopen')
    assert(vim.wait(1000, function() return #native_windows() == 0 and plugin.is_open() end), ':lopen 后原生窗口应被接管')
    local text = panel_text()
    assert(text:find('loc_b_marker', 1, true), '面板应展示所属窗口的位置列表: ' .. text)
    assert(not text:find('loc_a_marker', 1, true), '面板不得展示其他窗口的位置列表')
    plugin.close()

    -- 关闭配置后重复 setup：autocmd 真正移除，原生窗口保留
    plugin.setup({ lens = { enabled = false }, quickfix = { replace_native = false } })
    vim.api.nvim_set_current_win(win_a)
    vim.cmd('copen')
    local native = native_windows()[1]
    vim.wait(100)
    assert(native and vim.api.nvim_win_is_valid(native), 'replace_native=false 时应保留原生 quickfix 窗口')
    assert(not plugin.is_open(), 'replace_native=false 时不得打开 vv-symbols 面板')
    vim.cmd('cclose')
  end)
end

-- 同一 Lua 调用内禁用，确保 native_qf 的 scheduled 接管尚未交付
T['禁用后已排队的原生 quickfix 接管不得重开面板'] = function()
  child.lua_func(function()
    local plugin = require('vv-symbols')
    plugin.setup({ lens = { enabled = false }, mouse = false })
    local buf = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'local marker = 1' })
    vim.fn.setqflist({ { bufnr = buf, lnum = 1, text = 'marker' } }, 'r')
    vim.cmd('copen')
    local native = vim.api.nvim_get_current_win()
    plugin.disable()
    vim.wait(100, function() return false end)

    assert(not plugin.is_open(), 'disable 后旧接管回调不得重新开启插件面板')
    assert(vim.api.nvim_win_is_valid(native), 'disable 后不得再关闭原生 quickfix 窗口')
  end)
end

T['重新 attach 后旧接管回调失效且新接管仍可工作'] = function()
  child.lua_func(function()
    local native = require('vv-symbols.native_qf')
    local calls = {}
    local buf = vim.api.nvim_get_current_buf()
    vim.fn.setqflist({ { bufnr = buf, lnum = 1, text = 'marker' } }, 'r')
    native.attach({ open = function() calls[#calls + 1] = 'old' end })
    vim.cmd('copen')
    local window = vim.api.nvim_get_current_win()
    native.detach()
    native.attach({ open = function() calls[#calls + 1] = 'new' end })
    vim.wait(100, function() return false end)

    assert(#calls == 0 and vim.api.nvim_win_is_valid(window), '重新 attach 不得消费旧窗口的排队回调')
    vim.cmd('cclose')
    vim.cmd('copen')
    assert(vim.wait(1000, function() return #calls > 0 end), '新 attach 应接管随后打开的窗口')
    assert(vim.deep_equal(calls, { 'new' }), '只允许当前 attach 的回调执行')
    native.detach()
  end)
end

return T
