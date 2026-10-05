local H = dofile('tests/helpers.lua')
local T, child = H.new_set()

T['引用查询按需包含声明位置'] = function()
  child.lua_func(function()
    -- includeDeclaration 分流契约：lens 计数只看 references.include_declaration，
    -- 位置列表与 peek 的 references 请求看 locations.include_declaration（nil 跟随前者）

    local requests = {}
    local client = { id = 1, offset_encoding = 'utf-16', attached_buffers = {} }
    function client:supports_method() return true end
    function client:request(method, params, handler)
      requests[#requests + 1] = { method = method, params = params }
      local range = { start = { line = 0, character = 15 }, ['end'] = { line = 0, character = 20 } }
      -- 真实服务端异步应答
      vim.schedule(function()
        if method == 'textDocument/documentSymbol' then
          handler(nil, { { name = 'value', kind = 12, range = range, selectionRange = range } })
        else
          handler(nil, {})
        end
      end)
      return true, #requests
    end
    function client:cancel_request() end
    function client:stop() end
    local get_clients = vim.lsp.get_clients
    vim.lsp.get_clients = function() return { client } end

    local plugin = require('vv-symbols')
    local source = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_name(source, (vim.env.VV_TEST_TMP .. '/vv-symbols-include-declaration.lua'))
    vim.api.nvim_buf_set_lines(source, 0, -1, false, { 'local function value() end', 'value()' })

    ---按配置依次触发 lens、grr 与 peek references，返回各自 references 请求的 includeDeclaration
    local function capture(opts)
      requests = {}
      plugin.setup(vim.tbl_deep_extend('force', {
        lens = { scope = 'all' },
        locations = { jump_single_result = false },
        timing = { debounce_ms = 5 },
      }, opts))
      vim.api.nvim_set_current_buf(source)
      plugin.enable_lens()
      assert(
        vim.wait(200, function() return #requests >= 2 end, 5),
        'lens 应在 documentSymbol 之后发起 references 请求'
      )
      local lens = requests[2].params.context.includeDeclaration

      vim.api.nvim_set_current_buf(source)
      vim.api.nvim_win_set_cursor(0, { 2, 1 })
      local before = #requests
      plugin.references()
      assert(#requests == before + 1, 'grr 应发起一次 references 请求')
      local list = requests[#requests].params.context.includeDeclaration
      plugin.close()

      vim.api.nvim_set_current_buf(source)
      before = #requests
      plugin.peek({ method = 'references' })
      assert(#requests == before + 1, 'peek 应发起一次 references 请求')
      local peek = requests[#requests].params.context.includeDeclaration
      return { lens = lens, list = list, peek = peek }
    end

    local split = capture({ references = { include_declaration = false }, locations = { include_declaration = true } })
    assert(
      split.lens == false and split.list == true and split.peek == true,
      ('locations.include_declaration=true 只影响位置列表与 peek：%s'):format(vim.inspect(split))
    )

    local follow = capture({ references = { include_declaration = true } })
    assert(
      follow.lens == true and follow.list == true and follow.peek == true,
      ('locations.include_declaration 缺省应跟随 references：%s'):format(vim.inspect(follow))
    )

    local default = capture({})
    assert(
      default.lens == false and default.list == false and default.peek == false,
      ('默认均不包含声明：%s'):format(vim.inspect(default))
    )

    plugin.disable()
    vim.lsp.get_clients = get_clients
  end)
end

return T
