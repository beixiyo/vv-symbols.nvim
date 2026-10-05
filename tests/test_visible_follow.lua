local H = dofile('tests/helpers.lua')
local T, child = H.new_set()

T['可见窗口驱动 lens 跟随'] = function()
  child.lua_func(function()
    -- 焦点在非文件面板（如 vv-git 左栏）时，同 tab 可见的真实文件也要驱动 lens；
    -- 焦点在源码时不得被并排的其它文件抢占会话，scratch 预览不发请求
    local requests = {}
    package.loaded['vv-symbols.lsp'] = {
      symbols = function(opts, cb)
        requests[#requests + 1] = { buf = opts.buf, cb = cb }
        return function() end
      end,
      references = function(_, cb)
        cb(nil, { count = 3, locations = {}, encoding = 'utf-16' })
        return function() end
      end,
    }
    local plugin = require('vv-symbols')
    local namespace = vim.api.nvim_create_namespace('vv-symbols.lens')

    local function requested(buf)
      for _, req in ipairs(requests) do
        if req.buf == buf then return req end
      end
    end

    local function reply(req, name)
      local range = { start = { line = 0, character = 0 }, ['end'] = { line = 0, character = 23 } }
      req.cb(nil, {
        client_id = 1,
        encoding = 'utf-16',
        symbols = { { name = name, kind = 12, range = range, selectionRange = range } },
      })
    end

    local function file_buf(path, line)
      local buf = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_buf_set_name(buf, path)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { line })
      return buf
    end

    local function lens_count(buf) return #vim.api.nvim_buf_get_extmarks(buf, namespace, 0, -1, {}) end

    -- 左侧 nofile 面板持有焦点，右侧先显示只读 scratch 快照（vv-git 默认浏览形态）
    local panel = vim.api.nvim_get_current_buf()
    vim.bo[panel].buftype = 'nofile'
    vim.cmd('rightbelow vsplit')
    local right_win = vim.api.nvim_get_current_win()
    local snapshot = vim.api.nvim_create_buf(false, true)
    vim.bo[snapshot].buftype = 'nowrite'
    vim.api.nvim_buf_set_lines(snapshot, 0, -1, false, { 'local function shown() end' })
    vim.api.nvim_win_set_buf(right_win, snapshot)
    vim.cmd('wincmd p')
    assert(vim.api.nvim_get_current_buf() == panel)

    plugin.setup({ lens = { enabled = true, scope = 'all' }, timing = { debounce_ms = 10 } })
    vim.wait(50, function() return false end)
    assert(not requested(snapshot), 'scratch 快照不是真实文件，不得发起符号请求')

    -- 焦点留在左栏，右侧原地换成真实文件 buffer，随后 LSP attach
    local real = file_buf((vim.env.VV_TEST_TMP .. '/vv-symbols-visible-real.lua'), 'local function shown() end')
    vim.api.nvim_win_set_buf(right_win, real)
    vim.api.nvim_exec_autocmds('LspAttach', { buffer = real, modeline = false })
    assert(
      vim.wait(200, function() return requested(real) ~= nil end),
      '焦点在非文件面板时，同 tab 可见的真实文件必须发起符号请求'
    )
    assert(vim.api.nvim_get_current_buf() == panel, '跟随可见窗口不得转移焦点')
    reply(requests[#requests], 'shown')
    assert(
      vim.wait(200, function() return lens_count(real) == 1 end),
      '可见但未聚焦的真实文件应渲染引用计数'
    )

    -- 焦点进入右侧不应重复请求（快照未变）
    local before = #requests
    vim.api.nvim_set_current_win(right_win)
    vim.wait(50, function() return false end)
    assert(#requests == before, '进入已分析的可见文件不得重复请求')
    assert(lens_count(real) == 1)

    -- 焦点在源码时，并排窗口的 attach 不得抢占唯一会话
    local other = file_buf((vim.env.VV_TEST_TMP .. '/vv-symbols-visible-other.lua'), 'local function other() end')
    vim.cmd('rightbelow vsplit')
    local other_win = vim.api.nvim_get_current_win()
    vim.api.nvim_set_current_win(right_win)
    vim.api.nvim_win_set_buf(other_win, other)
    vim.api.nvim_exec_autocmds('LspAttach', { buffer = other, modeline = false })
    vim.wait(50, function() return false end)
    assert(not requested(other), '焦点在源码时，其它可见文件不得抢占会话')
    assert(lens_count(real) == 1, '当前源码的 lens 不得被清除')

    plugin.disable()
  end)
end

return T
