local H = dofile('tests/helpers.lua')
local T, child = H.new_set()

T['虚拟引用行的排布、过滤和边界'] = function()
  child.lua_func(function()
    local Lens = require('vv-symbols.lens')
    local Config = require('vv-symbols.config')
    local defaults = Config.normalize({})
    assert(
      defaults.lens.position == 'eol' and defaults.lens.label == 'refs',
      '默认值必须是 eol 位置加 refs 标签'
    )
    assert(defaults.lens.callable_only == false, 'callable_only 默认必须为 false（所有导出符号计数）')
    assert(defaults.peek.width_ratio == 0.8 and defaults.peek.height_ratio == 0.75, 'peek 几何默认值应为 0.8/0.75')
    local exported_variable = {
      id = 'variable',
      uri = 'file:///variable.lua',
      is_callable = false,
      exported = true,
      range = { start = { line = 1 } },
    }
    assert(Lens.matches(exported_variable) == true, '默认导出变量也应计入引用提示')
    assert(
      Lens.matches(exported_variable, { callable_only = true }) == false,
      'callable_only=true 时仅可调用符号计入'
    )
    assert(
      Lens.matches({ is_callable = false, exported = false, top_level = true, export_undetected = true }) == false,
      '无导出识别语言的顶层非可调用符号（markdown 标题等）不得凭豁免计数'
    )
    assert(
      Lens.matches({ is_callable = true, exported = false, top_level = true, export_undetected = true }) == true,
      '无导出识别语言的顶层函数仍视为模块 API'
    )
    assert(
      Lens.matches({ id = 'nested', uri = 'file:///variable.lua', is_callable = false, exported = false, top_level = false, export_undetected = true }) == false,
      '嵌套符号仍受 scope 约束'
    )
    assert(
      Lens.matches({ id = 'nested2', uri = 'file:///variable.lua', is_callable = false, exported = false, top_level = false, export_undetected = true }, { callable_only = true }) == false,
      'callable_only=true 时嵌套符号仍被排除'
    )
    assert(
      Lens.matches(exported_variable, { filter = function() return false end }) == false,
      '自定义 filter 不能被绕过'
    )
    local buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_name(buf, (vim.env.VV_TEST_TMP .. '/vv-symbols-lens.lua'))
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'function first() end', '  function second() end' })
    vim.api.nvim_set_current_buf(buf)
    vim.bo[buf].modifiable = false
    local uri = vim.uri_from_bufnr(buf)
    local own_ns = vim.api.nvim_get_namespaces()['vv-symbols.lens']
    local other_ns = vim.api.nvim_create_namespace('vv-symbols.test.other')
    vim.api.nvim_buf_set_extmark(buf, other_ns, 0, 0, { virt_text = { { 'other', 'Comment' } } })

    local nodes = {
      { id = 'first', uri = uri, is_callable = true, exported = true, range = { start = { line = 0 } } },
      { id = 'first-again', uri = uri, is_callable = true, exported = true, range = { start = { line = 0 } } },
      { id = 'second', uri = uri, is_callable = true, exported = true, range = { start = { line = 1 } } },
      { id = 'skipped', uri = uri, is_callable = true, exported = true, range = { start = { line = 0 } } },
      {
        id = 'foreign',
        uri = 'file:///elsewhere.lua',
        is_callable = true,
        exported = true,
        range = { start = { line = 0 } },
      },
      { id = 'out', uri = uri, is_callable = true, exported = true, range = { start = { line = 99 } } },
    }
    local count = Lens.render({
      buf = buf,
      nodes = nodes,
      results = {
        first = { status = 'pending' },
        ['first-again'] = { status = 'ready', count = 4 },
        second = { status = 'ready', count = 2 },
        skipped = { status = 'skipped' },
        foreign = { status = 'error', error = 'x' },
        out = { status = 'error', error = 'x' },
      },
      scope = 'all',
      position = 'above',
    })
    assert(count == 3, '只有 buffer 内支持的行才会创建 extmark')
    assert(
      vim.fn.winsaveview().topline == 1 and vim.fn.winsaveview().topfill >= 2,
      '首行可见虚拟行应预留足够 topfill，且不改变视口首行'
    )

    local own = vim.api.nvim_buf_get_extmarks(buf, own_ns, 0, -1, { details = true })
    assert(#own == 3, '每个可见符号应各有一条独立 extmark')
    local seen_first, seen_first_again, seen_second = false, false, false
    local first_marks = 0
    for _, mark in ipairs(own) do
      assert(mark[4].virt_lines_above == true, '引用提示必须位于符号行上方')
      local text = ''
      for _, chunk in ipairs(mark[4].virt_lines[1]) do
        text = text .. chunk[1]
      end
      if mark[2] == 0 then
        first_marks = first_marks + 1
        if text == ' … refs' then seen_first = true end
        if text == ' 4 refs' then
          seen_first_again = true
          assert(
            mark[4].virt_lines[1][2][2] == 'VVSymbolsReferenceCount',
            '引用数字必须独立高亮'
          )
        end
      elseif mark[2] == 1 then
        seen_second = text == '   2 refs'
        assert(mark[4].virt_lines[1][1][1] == '  ', '虚拟行应保留定义行缩进')
      end
    end
    assert(
      first_marks == 2 and seen_first and seen_first_again and seen_second,
      '同一行的两个提示必须各自可见且文案独立'
    )

    vim.fn.winrestview({ topfill = 0 })
    Lens.render({
      buf = buf,
      nodes = nodes,
      results = {
        first = { status = 'ready', count = 0 },
        ['first-again'] = { status = 'ready', count = 5 },
        second = { status = 'ready', count = 3 },
      },
      scope = 'all',
      position = 'above',
    })
    assert(
      vim.fn.winsaveview().topline == 1 and vim.fn.winsaveview().topfill == 0,
      '后续刷新不得回收用户手动移除的 topfill'
    )
    local zero
    for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, own_ns, 0, -1, { details = true })) do
      local chunks = mark[4].virt_lines[1]
      if chunks[2][1] == '0' then zero = chunks end
    end
    assert(zero and zero[2][2] == 'VVSymbolsZeroReferences', '零引用必须使用错误色')
    assert(zero[3][2] == 'VVSymbolsLens', '引用标签保持次级配色')

    vim.bo[buf].modifiable = true
    Lens.clear(buf)
    assert(#vim.api.nvim_buf_get_extmarks(buf, own_ns, 0, -1, {}) == 0, 'clear 应释放本模块命名空间的标记')
    assert(#vim.api.nvim_buf_get_extmarks(buf, other_ns, 0, -1, {}) == 1, 'clear 不得触碰其它命名空间')

    Lens.render({
      buf = buf,
      nodes = { nodes[1] },
      results = { first = { status = 'error', error = 'server failed' } },
      scope = 'all',
      position = 'above',
    })
    local error_mark = vim.api.nvim_buf_get_extmarks(buf, own_ns, 0, -1, { details = true })[1]
    assert(error_mark[4].virt_lines[1][2][1] == '? refs', '错误状态不得渲染成零引用')
    Lens.clear_all()
    assert(#vim.api.nvim_buf_get_extmarks(buf, own_ns, 0, -1, {}) == 0, 'clear_all 应释放所有已追踪标记')

    Lens.render({
      buf = buf,
      nodes = { nodes[1] },
      results = { first = { status = 'ready', count = 0 } },
      scope = 'all',
      position = 'eol',
    })
    local inline = vim.api.nvim_buf_get_extmarks(buf, own_ns, 0, -1, { details = true })[1][4]
    assert(inline.virt_text_pos == 'eol' and not inline.virt_lines, '行尾提示必须使用 eol 虚拟文本')
    assert(inline.virt_text[2][2] == 'VVSymbolsReferenceIcon', '链接图标必须使用主题高亮')
    assert(inline.virt_text[3][2] == 'VVSymbolsZeroReferences', '行内零引用保留红色计数高亮')
    Lens.render({ buf = buf, nodes = { nodes[1] }, results = { first = { status = 'ready', count = 2 } }, scope = 'all', position = 'above' })
    local above = vim.api.nvim_buf_get_extmarks(buf, own_ns, 0, -1, { details = true })
    assert(
      #above == 1 and above[1][4].virt_lines_above and not above[1][4].virt_text,
      '切换位置必须替换旧装饰'
    )
    assert(above[1][4].virt_lines[1][1][2] == 'VVSymbolsReferenceIcon', '上方虚拟行的图标使用同一高亮')

    Lens.render({
      buf = buf,
      nodes = { nodes[2] },
      results = { ['first-again'] = { status = 'ready', count = 7 } },
      scope = 'all',
      label = '引用',
    })
    local custom = vim.api.nvim_buf_get_extmarks(buf, own_ns, 0, -1, { details = true })[1][4]
    assert(
      custom.virt_text_pos == 'eol' and custom.virt_text[#custom.virt_text][1] == ' 引用',
      '默认渲染必须遵循自定义 label'
    )
    assert(
      vim.tbl_contains(vim.tbl_map(function(chunk) return chunk[1] end, custom.virt_text), '7'),
      '自定义 label 时计数仍需独立 chunk'
    )

    -- count_chunks：面板与 ufo 折叠行共用的计数 chunks 契约
    local ready_chunks = Lens.count_chunks({ status = 'ready', count = 3 })
    assert(
      ready_chunks
        and #ready_chunks == 3
        and ready_chunks[2][1] == '3'
        and ready_chunks[2][2] == 'VVSymbolsReferenceCount'
        and ready_chunks[3][1] == ' refs'
        and ready_chunks[3][2] == 'VVSymbolsLens',
      'ready 结果产出图标+数字+标签三段 chunks'
    )
    assert(
      Lens.count_chunks({ status = 'ready', count = 0 })[2][2] == 'VVSymbolsZeroReferences',
      '零引用沿用错误色高亮'
    )
    assert(
      Lens.count_chunks({ status = 'ready', count = 1 }, '引用')[3][1] == ' 引用',
      'count_chunks 支持自定义标签'
    )
    assert(
      Lens.count_chunks({ status = 'pending' }) == nil and Lens.count_chunks({ status = 'error' }) == nil,
      '非 ready 状态不产出 chunks（由调用方自行处理后缀）'
    )
    assert(
      Lens.count_chunks({ status = 'ready', count = 1 }, function(count) return count == 1 and 'ref' or 'refs' end)[3][1] == ' ref'
        and Lens.count_chunks({ status = 'ready', count = 2 }, function(count) return count == 1 and 'ref' or 'refs' end)[3][1] == ' refs',
      '函数形态 label 可按 count 处理单复数'
    )

    -- 无导出识别语言的顶层回退：顶层可调用视为模块 API，嵌套符号仍不算
    local py_top = { name = 'run', is_callable = true, exported = false, top_level = true, export_undetected = true }
    local py_method = { name = 'handle', is_callable = true, exported = false, top_level = false, export_undetected = true }
    local js_local = { name = 'helper', is_callable = true, exported = false, top_level = true, export_undetected = false }
    assert(Lens.matches(py_top) == true, '无导出识别语言的顶层函数视为模块 API')
    assert(Lens.matches(py_method) == false, '无导出识别语言的嵌套方法仍不算导出')
    assert(Lens.matches(js_local) == false, '有导出识别的语言仍按源码导出判断，顶层未导出不算')
    vim.api.nvim_buf_delete(buf, { force = true })
  end)
end

T['ft_ignore 中的文件类型不显示也不查询引用计数，侧栏不受影响'] = function()
  child.lua_func(function()
    -- 样式表的「引用」只是同文件内同名选择器的出现次数，不代表被使用的次数
    local symbol_requests, reference_requests = {}, 0
    local range = { start = { line = 0, character = 0 }, ['end'] = { line = 0, character = 5 } }
    package.loaded['vv-symbols.lsp'] = {
      symbols = function(opts, cb)
        symbol_requests[#symbol_requests + 1] = opts.buf
        cb(nil, {
          client_id = 1,
          encoding = 'utf-16',
          symbols = { { name = '.card', kind = 5, range = range, selectionRange = range } },
        })
        return function() end
      end,
      references = function(_, cb)
        reference_requests = reference_requests + 1
        cb(nil, { count = 0, locations = {}, encoding = 'utf-16' })
        return function() end
      end,
    }

    local Config = require('vv-symbols.config')
    assert(vim.deep_equal(Config.normalize({}).lens.ft_ignore, { 'css', 'scss', 'less' }))
    assert(vim.deep_equal(Config.normalize({ lens = { ft_ignore = { 'html' } } }).lens.ft_ignore, { 'html' }),
      '传入时整体覆盖默认值')

    local plugin = require('vv-symbols')
    plugin.setup({ lens = { scope = 'all' }, timing = { debounce_ms = 10 } })
    local namespace = vim.api.nvim_create_namespace('vv-symbols.lens')
    local function marks(buf) return #vim.api.nvim_buf_get_extmarks(buf, namespace, 0, -1, {}) end

    local function open(name, filetype)
      local buf = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_buf_set_name(buf, vim.env.VV_TEST_TMP .. '/' .. name)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { '.card { color: red; }' })
      vim.bo[buf].filetype = filetype
      vim.api.nvim_set_current_buf(buf)
      return buf
    end

    local css = open('lens-ignore.css', 'css')
    plugin.refresh({ buf = css })
    vim.wait(100, function() return false end)
    assert(marks(css) == 0, 'css 不应渲染引用计数')
    assert(reference_requests == 0 and #symbol_requests == 0, '被忽略的文件类型不应为 lens 发请求')

    -- 侧栏照常工作，且仍不查询引用
    plugin.open({ buf = css })
    assert(#symbol_requests == 1 and symbol_requests[1] == css, '侧栏需要的符号请求不受 ft_ignore 影响')
    vim.wait(50, function() return false end)
    assert(marks(css) == 0 and reference_requests == 0)
    plugin.close()

    -- 对照：未被忽略的文件类型照常计数
    local lua = open('lens-ignore.lua', 'lua')
    plugin.refresh({ buf = lua })
    assert(vim.wait(200, function() return marks(lua) == 1 end), '非忽略文件类型应渲染引用计数')
    assert(reference_requests >= 1, '非忽略文件类型应查询引用')

    -- 防抖期间 buffer 被删除：回调不得因读取已失效 buffer 的 filetype 而报错
    local errors = {}
    local schedule = vim.schedule
    vim.schedule = function(fn)
      return schedule(function()
        local ok, err = pcall(fn)
        if not ok then errors[#errors + 1] = err end
      end)
    end
    vim.api.nvim_buf_set_lines(lua, 0, -1, false, { '.card { color: blue; }' })
    vim.api.nvim_exec_autocmds('TextChanged', { buffer = lua })
    vim.api.nvim_buf_delete(lua, { force = true })
    vim.wait(100, function() return false end)
    vim.schedule = schedule
    assert(#errors == 0, vim.inspect(errors))
  end)
end

return T
