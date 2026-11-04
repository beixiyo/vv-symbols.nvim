local H = dofile('tests/helpers.lua')
local T, child = H.new_set()

T['peek 预览、确认、恢复与过期响应'] = function()
  child.lua_func(function()
    -- peek 浮窗契约：快照内容、多结果切换、底部按键提示、确认跳转、取消恢复与过期响应

    vim.o.columns, vim.o.lines = 160, 40

    local requests = {}
    package.preload['vv-symbols.lsp'] = function()
      return {
        locations = function(opts, callback)
          requests[#requests + 1] = { opts = opts, callback = callback }
          return function() end
        end,
      }
    end

    local Peek = require('vv-symbols.peek')

    local notices = {}
    local original_notify = vim.notify
    vim.notify = function(message, level)
      notices[#notices + 1] = { message = message, level = level }
    end

    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, 'p')
    local impl_a = dir .. '/impl-a.lua'
    local impl_b = dir .. '/impl-b.lua'
    vim.fn.writefile({ 'local a = 1', 'function impl_a()', '  return a', 'end', 'return impl_a' }, impl_a)
    vim.fn.writefile({ 'local b = 2', 'function impl_b()', '  return b', 'end', 'return impl_b' }, impl_b)

    local source_buf = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_name(source_buf, dir .. '/source.lua')
    vim.api.nvim_buf_set_lines(source_buf, 0, -1, false, { 'local iface = require("iface")', 'return iface' })
    local source_win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_cursor(source_win, { 1, 6 })

    local function location(path, line, col)
      return {
        uri = 'file://' .. path,
        range = { start = { line = line, character = col }, ['end'] = { line = line, character = col + 7 } },
      }
    end

    local peek_config = require('vv-symbols.config').normalize().peek

    local function open(opts)
      opts = opts or {}
      Peek.open({
        method = opts.method or 'implementation',
        buf = source_buf,
        cursor = opts.cursor or { line = 0, byte_col = 6 },
        peek = peek_config,
      })
      local request = requests[#requests]
      request.callback(nil, {
        locations = opts.locations,
        count = opts.locations and #opts.locations or 0,
        encoding = 'utf-16',
        client_id = 1,
      })
    end

    -- 单结果：浮窗打开、快照与光标落点正确
    open({ locations = { location(impl_a, 1, 9) } })
    assert(Peek.is_open(), '有结果时浮窗应打开')
    local peek_win = vim.fn.win_getid(vim.fn.winnr())
    assert(peek_win ~= source_win, '浮窗应持有焦点')
    local snapshot = vim.api.nvim_win_get_buf(peek_win)
    assert(vim.api.nvim_buf_get_lines(snapshot, 0, -1, false)[1] == 'local a = 1', '浮窗应显示目标文件快照')
    assert(
      vim.deep_equal(vim.api.nvim_win_get_cursor(peek_win), { 2, 9 }),
      '光标应落在实现 selection 范围起点'
    )
    assert(vim.bo[snapshot].modifiable == false, '快照 buffer 应为只读')
    assert(vim.wo[peek_win].number == true, '浮窗应显示行号')
    assert(vim.wo[peek_win].statuscolumn == '', '浮窗不应继承 statuscolumn 自绘（nofile 下只会是空白列）')
    assert(vim.api.nvim_buf_is_valid(source_buf) and vim.api.nvim_win_get_buf(source_win) == source_buf, '源窗口不应被替换')

    local function footer_text(win)
      local parts = {}
      for _, chunk in ipairs(vim.api.nvim_win_get_config(win).footer or {}) do parts[#parts + 1] = chunk[1] end
      return table.concat(parts)
    end

    -- 底部提示只列真实生效的键：单结果时 ]p / [p 无操作，不展示；confirm 与 jump 合并为一条
    assert(footer_text(peek_win) == ' ↵/gf Jump  q Close ', '单结果 footer 应只提示跳转与关闭：' .. footer_text(peek_win))

    -- 多结果切换：]p / [p 环形切换并复用同一浮窗与快照 buffer
    open({ locations = { location(impl_a, 1, 9), location(impl_b, 1, 9) } })
    assert(vim.fn.win_getid(vim.fn.winnr()) == peek_win, '新结果应复用同一浮窗')
    assert(vim.api.nvim_win_get_buf(peek_win) == snapshot, '复用会话应复用同一快照 buffer')
    assert(
      footer_text(peek_win) == ' ↵/gf Jump  ]p Next  [p Prev  q Close ',
      '多结果 footer 应提示切换键：' .. footer_text(peek_win)
    )
    Peek.select(1)
    assert(
      vim.api.nvim_buf_get_lines(snapshot, 0, -1, false)[1] == 'local b = 2',
      ']p 应切换到第二个实现的快照'
    )
    assert(
      vim.api.nvim_win_get_cursor(peek_win)[1] == 2,
      '切换后光标应落在第二个实现的起始行'
    )
    Peek.select(1)
    Peek.select(1)
    assert(
      vim.api.nvim_buf_get_lines(snapshot, 0, -1, false)[1] == 'local b = 2',
      '环形切换三步后应回到第二个实现'
    )

    local function key(keys)
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), 'xt', false)
    end

    -- q 关闭：浮窗释放、焦点回源窗口
    key('q')
    assert(not Peek.is_open(), 'q 应关闭浮窗')
    assert(vim.api.nvim_get_current_win() == source_win, '关闭后焦点应回源窗口')
    assert(not vim.api.nvim_buf_is_valid(snapshot), '快照 buffer 应随浮窗释放')

    -- 确认跳转：源窗口加载目标文件并落到实现位置
    open({ locations = { location(impl_a, 1, 9) } })
    key('<CR>')
    assert(not Peek.is_open(), '确认后浮窗应关闭')
    assert(vim.api.nvim_get_current_win() == source_win, '确认后焦点应在源窗口')
    assert(
      vim.uv.fs_realpath(vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(source_win)))
        == vim.uv.fs_realpath(impl_a),
      '确认应把源窗口切到目标文件'
    )
    assert(vim.deep_equal(vim.api.nvim_win_get_cursor(source_win), { 2, 9 }), '确认应跳到实现范围起点')
    vim.api.nvim_win_set_buf(source_win, source_buf)

    -- 浮窗内浏览后确认：跳到浮窗光标当前行，而非 location 范围起点
    open({ locations = { location(impl_a, 1, 9) } })
    local browse_win = vim.fn.win_getid(vim.fn.winnr())
    vim.api.nvim_win_set_cursor(browse_win, { 4, 0 })
    key('<CR>')
    assert(
      vim.deep_equal(vim.api.nvim_win_get_cursor(source_win), { 4, 0 }),
      '浏览后确认应跳到浮窗光标行'
    )
    vim.api.nvim_win_set_buf(source_win, source_buf)

    -- gf 同样触发跳转
    open({ locations = { location(impl_b, 1, 9) } })
    local gf_win = vim.fn.win_getid(vim.fn.winnr())
    vim.api.nvim_win_set_cursor(gf_win, { 3, 0 })
    key('gf')
    assert(not Peek.is_open(), 'gf 后浮窗应关闭')
    assert(
      vim.uv.fs_realpath(vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(source_win)))
        == vim.uv.fs_realpath(impl_b),
      'gf 应把源窗口切到目标文件'
    )
    assert(vim.deep_equal(vim.api.nvim_win_get_cursor(source_win), { 3, 0 }), 'gf 应跳到浮窗光标行')
    vim.api.nvim_win_set_buf(source_win, source_buf)

    -- 零结果：不打开浮窗并给出提示
    notices = {}
    open({ locations = {} })
    assert(not Peek.is_open(), '零结果不应打开浮窗')
    assert(#notices == 1 and notices[1].level == vim.log.levels.INFO, '零结果应有 INFO 提示')

    -- 过期响应：新请求取消旧请求，慢到的旧结果不得写回
    Peek.open({ method = 'implementation', buf = source_buf, cursor = { line = 0, byte_col = 6 }, peek = peek_config })
    local stale = requests[#requests]
    Peek.open({ method = 'implementation', buf = source_buf, cursor = { line = 0, byte_col = 6 }, peek = peek_config })
    local current = requests[#requests]
    current.callback(nil, {
      locations = { location(impl_b, 1, 9) },
      count = 1,
      encoding = 'utf-16',
      client_id = 1,
    })
    stale.callback(nil, {
      locations = { location(impl_a, 1, 9) },
      count = 1,
      encoding = 'utf-16',
      client_id = 1,
    })
    local active = vim.api.nvim_win_get_buf(vim.fn.win_getid(vim.fn.winnr()))
    assert(
      vim.api.nvim_buf_get_lines(active, 0, -1, false)[1] == 'local b = 2',
      '迟到的旧响应不得覆盖新结果'
    )

    -- peek.size：content 按内容自适应，比例只作上限；screen 直接按比例占 editor
    local function peek_size(peek)
      Peek.close(true)
      Peek.open({ method = 'implementation', buf = source_buf, cursor = { line = 0, byte_col = 6 }, peek = peek })
      requests[#requests].callback(nil, {
        locations = { location(impl_a, 1, 9) },
        count = 1,
        encoding = 'utf-16',
        client_id = 1,
      })
      local win = vim.fn.win_getid(vim.fn.winnr())
      return vim.api.nvim_win_get_width(win), vim.api.nvim_win_get_height(win)
    end
    local available = vim.o.lines - vim.o.cmdheight - 2
    local width, height = peek_size({ size = 'screen', width_ratio = 0.5, height_ratio = 0.4, border = 'rounded' })
    assert(
      width == math.floor(vim.o.columns * 0.5) and height == math.floor(available * 0.4),
      ('size=screen 应按比例占 editor，实际 %dx%d'):format(width, height)
    )
    width = peek_size({ size = 'content', width_ratio = 0.5, height_ratio = 0.4, border = 'rounded' })
    assert(width < math.floor(vim.o.columns * 0.5), 'size=content 的短内容不应撑满宽度上限')
    Peek.close(true)

    -- 源窗口关闭：浮窗随之关闭
    vim.api.nvim_set_current_win(source_win)
    vim.cmd('vsplit')
    vim.api.nvim_win_close(source_win, false)
    assert(not Peek.is_open(), '源窗口关闭后浮窗应一并关闭')

    vim.notify = original_notify
  end)
end

T['实际关闭预览时取消在途请求并释放等待帧'] = function()
  child.lua_func(function()
    local requests = {}
    package.loaded['vv-symbols.lsp'] = {
      locations = function(opts, callback)
        local request = { method = opts.method, callback = callback, cancelled = 0 }
        requests[#requests + 1] = request
        return function()
          request.cancelled = request.cancelled + 1
          -- 取消期间同步到达的响应也必须先失效，不能继续发起后备查询
          callback(nil, { locations = {} })
        end
      end,
    }
    local Loading = require('vv-symbols.loading')
    local start = Loading.start
    local handle
    Loading.start = function(target)
      handle = start(target)
      return handle
    end
    local Peek = require('vv-symbols.peek')
    local UiPeek = require('vv-utils.ui_peek')
    local peek_config = require('vv-symbols.config').normalize().peek
    local base = vim.api.nvim_get_current_win()
    local path = vim.env.VV_TEST_TMP .. '/target.lua'
    vim.fn.writefile({ 'function target() end' }, path)
    local result = {
      encoding = 'utf-16',
      locations = { {
        uri = vim.uri_from_fname(path),
        range = { start = { line = 0, character = 9 }, ['end'] = { line = 0, character = 15 } },
      } },
    }
    for _, close in ipairs({ 'q', '<Esc>', '<CR>', 'source_window' }) do
      for _, fallback in ipairs({ false, true }) do
        vim.api.nvim_set_current_win(base)
        vim.cmd('vsplit')
        local source = vim.api.nvim_get_current_win()
        local buf = vim.api.nvim_create_buf(true, false)
        vim.api.nvim_win_set_buf(source, buf)
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'target()' })
        local function open()
          Peek.open({
            method = 'implementation',
            fallback_method = fallback and 'definition' or nil,
            buf = buf,
            cursor = { line = 0, byte_col = 0 },
            peek = peek_config,
          })
        end
        open()
        requests[#requests].callback(nil, result)
        local snapshot = assert(UiPeek.current())
        -- 从源码重新查询；旧预览仍可关闭或确认，新的结果尚未到达
        vim.api.nvim_set_current_win(source)
        open()
        if fallback then requests[#requests].callback(nil, { locations = {} }) end
        local pending = requests[#requests]
        assert(handle:is_active(), '在途查询应持有等待帧')
        if close == 'source_window' then
          vim.api.nvim_win_close(source, true)
        else
          vim.api.nvim_set_current_win(snapshot.win)
          vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(close, true, false, true), 'xt', false)
        end
        assert(pending.cancelled == 1, close .. ' 应恰好取消一次当前请求')
        assert(not handle:is_active(), close .. ' 应停止等待帧')
        assert(not UiPeek.is_open() and not Peek.is_open(), close .. ' 应关闭预览会话')
        assert(not vim.api.nvim_buf_is_valid(snapshot.buf), close .. ' 应释放快照')
        -- 物理取消也可能挡不住已在事件队列中的响应
        pending.callback(nil, result)
        assert(not UiPeek.is_open(), '迟到响应不得重建浮窗或抛出空状态异常')
        Peek.close(true)
        assert(pending.cancelled == 1, '重复关闭不得重复取消已清理请求')
        if vim.api.nvim_win_is_valid(source) then vim.api.nvim_win_close(source, true) end
      end
    end
  end)
end

T['auto 首选查询报错时回退定义，显式查询保留实际错误'] = function()
  child.lua_func(function()
    local requests, notices = {}, {}
    package.loaded['vv-symbols.lsp'] = {
      locations = function(opts, callback)
        requests[#requests + 1] = { method = opts.method, callback = callback }
        return function() end
      end,
    }
    vim.notify = function(message) notices[#notices + 1] = message end
    local Peek = require('vv-symbols.peek')
    local UiPeek = require('vv-utils.ui_peek')
    local buf = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'web.Assets()' })
    local path = vim.env.VV_TEST_TMP .. '/assets.go'
    vim.fn.writefile({ 'package web', 'func Assets() {}' }, path)
    local opts = {
      method = 'implementation', fallback_method = 'definition', buf = buf,
      cursor = { line = 0, byte_col = 4 }, peek = require('vv-symbols.config').normalize().peek,
    }
    -- 真实 gopls 对普通函数返回错误，而不是空 implementation 列表
    local err = { code = 0, message = "Assets is a function, not a method (query at 'func' token to find matching signatures)" }
    Peek.open(opts)
    requests[1].callback(err)
    assert(#requests == 2 and requests[2].method == 'definition', 'auto 首选报错必须继续查询定义')
    assert(#notices == 0, '成功回退前不应显示首选查询错误')
    requests[2].callback(nil, {
      encoding = 'utf-16',
      locations = { { uri = vim.uri_from_fname(path), range = {
        start = { line = 1, character = 5 }, ['end'] = { line = 1, character = 11 },
      } } },
    })
    assert(Peek.is_open(), '回退定义成功必须打开预览')
    assert(vim.api.nvim_buf_get_lines(UiPeek.current().buf, 1, 2, false)[1] == 'func Assets() {}', '必须预览定义文件')
    Peek.close(true)

    opts.fallback_method = nil
    Peek.open(opts)
    requests[3].callback(err)
    assert(#requests == 3 and not Peek.is_open(), '显式 implementation 不应悄悄回退')
    assert(notices[1] == 'vv-symbols: ' .. err.message, '错误对象应显示服务端消息而不是 table 地址')

    opts.fallback_method = 'definition'
    Peek.open(opts)
    requests[4].callback(err)
    requests[5].callback({ code = -32603, message = 'definition failed' })
    assert(#requests == 5 and not Peek.is_open(), '后备失败应终止，不能循环回退')
    assert(notices[2] == 'vv-symbols: definition failed', '最终错误应显示后备查询的消息')
  end)
end

return T
