local H = dofile('tests/helpers.lua')
local T, child = H.new_set()

T['LSP 等待帧落点与终结释放'] = function()
  child.lua_func(function()
    -- LSP 等待帧契约：首次结果前帧在源码标识符末尾 / 面板符号名后，结果、失效、新请求或关闭后不残留
    vim.o.columns, vim.o.lines = 180, 45

    local pending, symbol_requests = {}, {}
    package.loaded['vv-symbols.lsp'] = {
      symbols = function(opts, callback)
        symbol_requests[#symbol_requests + 1] = { opts = opts, callback = callback }
        return function() end
      end,
      locations = function(opts, callback)
        pending[#pending + 1] = { opts = opts, callback = callback }
        return function() end
      end,
    }
    local plugin = require('vv-symbols')
    local Peek = require('vv-symbols.peek')
    local peek_config = require('vv-symbols.config').normalize().peek
    plugin.setup({ lens = { enabled = false }, locations = { jump_single_result = true }, timing = { debounce_ms = 5 } })

    ---buffer 内全部 inline 虚拟文本：{ row, col, text }，row/col 零基
    local function frames(buf)
      local result = {}
      for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, -1, 0, -1, { details = true })) do
        local details = mark[4]
        if details.virt_text_pos == 'inline' and details.virt_text then
          result[#result + 1] = { row = mark[2], col = mark[3], text = details.virt_text[1][1] }
        end
      end
      return result
    end

    -- 等过 150ms 延迟，帧应已绘制
    local function settle() vim.wait(260, function() return false end) end

    local source = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_name(source, (vim.env.VV_TEST_TMP .. '/vv-symbols-loading-main.ts'))
    vim.api.nvim_buf_set_lines(source, 0, -1, false, { 'const localValue = 1', 'consume(localValue).then(done)' })
    local location = function(line, character)
      return {
        uri = vim.uri_from_bufnr(source),
        range = { start = { line = line, character = character }, ['end'] = { line = line, character = character + 10 } },
      }
    end

    -- S1：光标在标识符中间，帧落在词尾（consume(localValue 的 e 之后，字节列 18），首次结果到达后消失
    vim.api.nvim_win_set_cursor(0, { 2, 11 })
    plugin.references()
    assert(#frames(source) == 0, '150ms 内不应出现帧')
    settle()
    local shown = frames(source)
    assert(#shown == 1 and shown[1].row == 1 and shown[1].col == 18, vim.inspect(shown))
    pending[#pending].callback(nil, { locations = { location(0, 6), location(1, 8) }, encoding = 'utf-16' })
    assert(#frames(source) == 0, '首次结果展示后帧必须停止：' .. vim.inspect(frames(source)))
    plugin.close()

    -- S1：单结果直接跳转同样停止帧
    vim.api.nvim_set_current_buf(source)
    vim.api.nvim_win_set_cursor(0, { 2, 11 })
    plugin.references()
    settle()
    assert(#frames(source) == 1)
    pending[#pending].callback(nil, { locations = { location(0, 6) }, encoding = 'utf-16' })
    assert(#frames(source) == 0, '单结果跳转后帧必须停止')
    assert(not plugin.is_open(), '单结果应直接跳转而不打开面板')

    -- S1：等待中源码变化使请求失效，帧随之消失；晚到响应不得重新画帧
    vim.api.nvim_win_set_cursor(0, { 2, 11 })
    plugin.references()
    settle()
    local stale = pending[#pending]
    assert(#frames(source) == 1)
    vim.api.nvim_buf_set_lines(source, 0, 0, false, { '// edit' })
    vim.api.nvim_exec_autocmds('TextChanged', { buffer = source })
    assert(#frames(source) == 0, 'TextChanged 取消请求后帧必须停止')
    stale.callback(nil, { locations = { location(1, 6) }, encoding = 'utf-16' })
    settle()
    assert(#frames(source) == 0, '过期响应不得恢复帧')
    plugin.close()

    -- S1：新一次查询取代在途查询，只保留一个帧
    vim.api.nvim_set_current_buf(source)
    vim.api.nvim_buf_set_lines(source, 0, 1, false, {})
    vim.api.nvim_win_set_cursor(0, { 2, 11 })
    plugin.references()
    settle()
    vim.api.nvim_win_set_cursor(0, { 1, 7 })
    plugin.references()
    settle()
    shown = frames(source)
    assert(#shown == 1 and shown[1].row == 0 and shown[1].col == 16, '新查询应停掉旧帧：' .. vim.inspect(shown))
    plugin.close()
    assert(#frames(source) == 0, '关闭后不得残留帧')

    -- S1b：从符号面板发起 references，帧在面板所选符号名后、kind 前；源码 buffer 不画帧
    vim.api.nvim_set_current_buf(source)
    plugin.open()
    local panel_buf = vim.api.nvim_get_current_buf()
    local range = { start = { line = 0, character = 6 }, ['end'] = { line = 0, character = 16 } }
    symbol_requests[#symbol_requests].callback(nil, {
      symbols = { { name = 'localValue', kind = 13, range = range, selectionRange = range } },
      client_id = 1,
      encoding = 'utf-16',
    })
    local symbol_line = vim.fn.search('localValue', 'cw')
    assert(symbol_line > 0, table.concat(vim.api.nvim_buf_get_lines(panel_buf, 0, -1, false), '\n'))
    vim.api.nvim_feedkeys('R', 'x', false)
    settle()
    assert(#frames(source) == 0, '面板发起时源码不应画帧')
    shown = frames(panel_buf)
    local text = vim.api.nvim_buf_get_lines(panel_buf, symbol_line - 1, symbol_line, false)[1]
    local name_end = select(2, text:find('localValue', 1, true))
    assert(#shown == 1 and shown[1].row == symbol_line - 1 and shown[1].col == name_end, vim.inspect({ shown, text }))
    pending[#pending].callback(nil, { locations = { location(0, 6), location(1, 8) }, encoding = 'utf-16' })
    assert(#frames(panel_buf) == 0, '引用列表出现后面板帧必须停止')
    plugin.close()

    -- S2：peek 等待帧落点同 S1；新一次 peek 停掉旧帧，旧请求的晚到回调不影响新帧，结果到达后消失
    vim.api.nvim_set_current_buf(source)
    Peek.open({ method = 'definition', buf = source, cursor = { line = 1, byte_col = 11 }, peek = peek_config })
    local first = pending[#pending]
    settle()
    shown = frames(source)
    assert(#shown == 1 and shown[1].row == 1 and shown[1].col == 18, vim.inspect(shown))
    Peek.open({ method = 'definition', buf = source, cursor = { line = 1, byte_col = 21 }, peek = peek_config })
    local second = pending[#pending]
    settle()
    shown = frames(source)
    assert(#shown == 1 and shown[1].col == 24, '新 peek 不得残留旧帧：' .. vim.inspect(shown))
    first.callback(nil, { locations = {}, encoding = 'utf-16' })
    settle()
    assert(#frames(source) == 1, '过期回调不得停掉新 peek 的帧')
    second.callback(nil, { locations = { location(0, 6) }, encoding = 'utf-16' })
    assert(#frames(source) == 0, 'peek 结果出现后帧必须停止')
    Peek.close(false)

    -- S2：等待中关闭 peek 停止帧
    Peek.open({ method = 'definition', buf = source, cursor = { line = 1, byte_col = 11 }, peek = peek_config })
    settle()
    assert(#frames(source) == 1)
    Peek.close(false)
    assert(#frames(source) == 0, 'peek 关闭后不得残留帧')
  end)
end

return T
