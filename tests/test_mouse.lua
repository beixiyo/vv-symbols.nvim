local H = dofile('tests/helpers.lua')
local T, child = H.new_set()

T['Ctrl 鼠标跳转、下划线与映射所有权'] = function()
  -- Ctrl+鼠标契约：Ctrl+左键在点击处调用定义跳转（跨窗口、面板不拦截）、Ctrl 悬停下划线整个标识符并随移动清除、
  -- 关闭配置不安装映射且不覆盖用户同键映射
  -- 用 --embed 子进程驱动真实鼠标输入（nvim_input_mouse 需经主循环的按键/映射解析，-l 进程内无法驱动）
  local root = vim.env.VV_TEST_REPO

  local function lua(code, ...) return child.lua(code, { ... }) end

  -- row / col 相对窗口文本区（跳过行号列），与 getmousepos 的 line / column 对齐
  local function mouse(button, action, win, row, col)
    local pos = lua('return vim.api.nvim_win_get_position(...)', win)
    col = col + lua('return vim.fn.getwininfo(...)[1].textoff', win)
    child.api.nvim_input_mouse( button, action, 'C', 0, pos[1] + row, pos[2] + col)
    vim.wait(80)
  end

  local function plain_move(win, row, col)
    local pos = lua('return vim.api.nvim_win_get_position(...)', win)
    child.api.nvim_input_mouse( 'move', '', '', 0, pos[1] + row, pos[2] + col)
    vim.wait(80)
  end

  local function marks(buf)
    return lua([[
      local ns = vim.api.nvim_get_namespaces()['vv-symbols.mouse']
      if not ns then return {} end
      local out = {}
      for _, m in ipairs(vim.api.nvim_buf_get_extmarks(..., ns, 0, -1, { details = true })) do
        out[#out + 1] = { row = m[2], start_col = m[3], end_col = m[4].end_col, hl = m[4].hl_group }
      end
      return out
    ]], buf)
  end

  local ok, err = pcall(function()
    local env = lua([[
      local root = ...
      vim.opt.rtp:prepend(root)
      vim.opt.rtp:prepend(vim.env.VV_UTILS)
      vim.o.mouse = 'a'
      vim.o.mousemoveevent = false

      local code = vim.api.nvim_get_current_buf()
      vim.api.nvim_buf_set_name(code, (vim.env.VV_TEST_TMP .. '/vv-symbols-mouse.lua'))
      vim.api.nvim_buf_set_lines(code, 0, -1, false, { 'local foo_bar = baz(1)', 'return foo_bar' })
      local code_win = vim.api.nvim_get_current_win()
      vim.wo[code_win].number = true

      -- 进程内 LSP：只声明 definitionProvider，让真实的 vim.lsp.get_clients 过滤生效
      vim.lsp.start({
        name = 'fake-definition',
        cmd = function(dispatchers)
          local closing = false
          return {
            request = function(method, _, callback)
              if method == 'initialize' then
                callback(nil, { capabilities = { definitionProvider = true } })
              else
                callback(nil, nil)
              end
              return true, 1
            end,
            notify = function() return true end,
            is_closing = function() return closing end,
            terminate = function() closing = true end,
          }
        end,
        root_dir = vim.env.VV_TEST_TMP,
      }, { bufnr = code })
      assert(vim.wait(1000, function() return #vim.lsp.get_clients({ bufnr = code }) > 0 end), 'LSP 客户端应已附着')

      vim.cmd('vnew')
      local panel_win = vim.api.nvim_get_current_win()
      local panel = vim.api.nvim_get_current_buf()
      vim.bo[panel].buftype = 'nofile'
      vim.api.nvim_buf_set_lines(panel, 0, -1, false, { 'local foo_bar = baz(1)' })
      -- 面板也挂上客户端，确保拦截判定靠 buftype 而不是恰好没有 LSP
      assert(vim.lsp.buf_attach_client(panel, vim.lsp.get_clients({ bufnr = code })[1].id), '面板应附着 LSP 客户端')

      -- 没有 LSP 的普通文件 buffer
      vim.cmd('new')
      local plain_win = vim.api.nvim_get_current_win()
      vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'local foo_bar = baz(1)' })

      local plugin = require('vv-symbols')
      plugin.setup({ lens = { enabled = false } })
      _G.calls = {}
      plugin.locations = function(opts)
        local cursor = vim.api.nvim_win_get_cursor(0)
        _G.calls[#_G.calls + 1] = { buf = opts.buf, method = opts.method, win = vim.api.nvim_get_current_win(), cursor = cursor }
      end
      return { code = code, code_win = code_win, panel = panel, panel_win = panel_win, plain_win = plain_win, mev = vim.o.mousemoveevent }
    ]], root)
    assert(env.mev == true, 'underline 启用时应打开 mousemoveevent')

    -- 焦点在面板时 Ctrl+左键点源码 foo_bar 的中间：切到源码窗口、光标落在点击处，再走 definition
    mouse('left', 'press', env.code_win, 0, 9)
    mouse('left', 'release', env.code_win, 0, 9)
    local calls = lua('return _G.calls')
    assert(#calls == 1, 'Ctrl+左键应调用一次定义跳转: ' .. vim.inspect(calls))
    assert(calls[1].buf == env.code and calls[1].method == 'definition', vim.inspect(calls[1]))
    assert(calls[1].win == env.code_win, '应先切到被点击的窗口')
    assert(calls[1].cursor[1] == 1 and calls[1].cursor[2] == 9, '光标应在点击处: ' .. vim.inspect(calls[1].cursor))

    assert(child.v.errmsg == '', '插件接管的定义跳转不得触发原生 tag 错误')

    -- 行号列与面板 buffer 不拦截
    mouse('left', 'press', env.code_win, 1, -1)
    mouse('left', 'press', env.panel_win, 0, 9)
    mouse('left', 'press', env.plain_win, 0, 9)
    assert(#lua('return _G.calls') == 1, '行号列、面板与无 LSP 的 buffer 中 Ctrl+左键必须交还原生行为')
    -- 0.13+ 原生 <C-LeftMouse> 是放置多光标，nvim_mcursor 返回全部额外光标数：上面三次交还 + 本次 = 4
    local extra = lua([[
      if not vim.api.nvim_mcursor then return false end
      return vim.api.nvim_mcursor(vim.api.nvim_win_get_buf(...), { 1, 20 })
    ]], env.plain_win)
    assert(extra == false or extra == 4, '交还后应执行原生多光标，实际额外光标数: ' .. tostring(extra))
    if extra == false then
      -- 0.12 原生 Ctrl+左键是 tag 跳转；无 tags 的 fixture 必须报这个精确错误，而非插件拦截
      assert(child.v.errmsg == 'E426: Tag not found: foo_bar', '交还原生 tag 跳转应产生准确的缺失 tag 错误')
      child.v.errmsg = ''
    else
      assert(child.v.errmsg == '', '原生多光标分支不得产生 tag 错误')
    end

    -- Ctrl 悬停：覆盖整个标识符；同一标识符内移动不重画；移到空白清除
    mouse('move', '', env.code_win, 0, 8)
    local m = marks(env.code)
    assert(#m == 1 and m[1].row == 0 and m[1].start_col == 6 and m[1].end_col == 13, vim.inspect(m))
    assert(m[1].hl == 'VVSymbolsLink', vim.inspect(m))
    mouse('move', '', env.code_win, 0, 12)
    assert(#marks(env.code) == 1, '同一标识符内移动应保持单个下划线')
    mouse('move', '', env.code_win, 0, 13)
    assert(#marks(env.code) == 0, '移到空白应清除下划线')
    mouse('move', '', env.panel_win, 0, 8)
    assert(#marks(env.panel) == 0, '面板 buffer 不加下划线')

    -- 松开 Ctrl 后的普通移动清除
    mouse('move', '', env.code_win, 1, 9)
    assert(#marks(env.code) == 1, '第二行 foo_bar 应有下划线')
    plain_move(env.code_win, 1, 2)
    assert(#marks(env.code) == 0, '普通移动应清除下划线')

    -- 用户已有同键全局映射：不覆盖；关闭配置后自有映射移除、用户映射保留、mousemoveevent 关回
    local state = lua([[
      local plugin = require('vv-symbols')
      plugin.disable()
      vim.keymap.set('n', '<C-LeftMouse>', function() _G.user_click = true end, { desc = 'user click' })
      plugin.setup({ lens = { enabled = false } })
      local function desc(lhs)
        for _, map in ipairs(vim.api.nvim_get_keymap('n')) do
          if map.lhs == lhs then return map.desc or '' end
        end
        return false
      end
      local enabled = { click = desc('<C-LeftMouse>'), move = desc('<C-MouseMove>') }
      plugin.setup({ lens = { enabled = false }, mouse = false })
      return {
        enabled = enabled,
        disabled = { click = desc('<C-LeftMouse>'), move = desc('<C-MouseMove>') },
        mev = vim.o.mousemoveevent,
      }
    ]])
    assert(state.enabled.click == 'user click', '不得覆盖用户已有的 <C-LeftMouse>')
    assert(state.enabled.move == 'vv-symbols: underline definition link', vim.inspect(state.enabled))
    assert(state.disabled.click == 'user click' and state.disabled.move == false, vim.inspect(state.disabled))
    assert(state.mev == false, 'mouse 关闭后应关回由插件打开的 mousemoveevent')
  end)

  assert(ok, err)
end

return T
