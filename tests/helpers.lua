-- 每个具名场景拥有独立子进程和隔离临时 fixture；失败路径也停止进程并清理目录
local M = {}

function M.new_set()
  local MiniTest = require('mini.test')
  local child = MiniTest.new_child_neovim()
  local root
  local T = MiniTest.new_set({
    hooks = {
      pre_case = function()
        local temp_root = assert(vim.uv.fs_realpath(assert(vim.env.TMPDIR)))
        -- 短路径兼容 macOS RPC socket 上限；fixture 必须归属共享临时根
        root = assert(vim.uv.fs_mkdtemp(temp_root .. '/cXXXXXX'))
        assert(vim.uv.fs_realpath(vim.fs.dirname(root)) == temp_root, 'fixture 必须位于隔离临时目录')
        local environment = {
          VV_TEST_TMP = root,
          HOME = root .. '/home',
          TMPDIR = root .. '/tmp',
          XDG_CONFIG_HOME = root .. '/config',
          XDG_DATA_HOME = root .. '/data',
          XDG_STATE_HOME = root .. '/state',
          XDG_CACHE_HOME = root .. '/cache',
        }
        local previous = {}
        local cwd, tempname = vim.fn.getcwd(), vim.fn.tempname
        for name, value in pairs(environment) do
          previous[name] = vim.env[name]
          vim.fn.mkdir(value, 'p')
          vim.env[name] = value
        end
        -- pinned mini.test 的 start 不接受 env/cwd：仅在启动期间借用父环境，随后无条件归还
        vim.cmd.cd(vim.fn.fnameescape(root))
        vim.fn.tempname = function()
          return root .. '/child.sock'
        end
        local started, start_err = pcall(child.start, { '-u', 'NONE', '-i', 'NONE', '-n' }, {
          nvim_executable = vim.v.progpath,
        })
        vim.fn.tempname = tempname
        vim.cmd.cd(vim.fn.fnameescape(cwd))
        for name in pairs(environment) do
          vim.env[name] = previous[name]
        end
        assert(started, start_err)
        child.lua([[
        local root = assert(vim.env.VV_TEST_TMP, 'fixture 路径不能为空')
        assert(root ~= '', 'fixture 路径不能为空')
        vim.opt.packpath = ''
        dofile(vim.env.VV_UTILS .. '/dev/test/runtime.lua').apply()
        vim.opt.runtimepath:prepend(vim.env.VV_TEST_REPO)
        vim.opt.runtimepath:prepend(vim.env.VV_UTILS)
        -- 保留原 site 查询优先于 Neovim 内置查询的契约
        vim.opt.runtimepath:prepend(assert(vim.env.VV_TEST_PARSERS))
        vim.opt.runtimepath:prepend(assert(vim.env.VV_TEST_QUERIES))
        -- 所有临时文件归属当前 case，父 hook 清理失败时留下的文件
        local serial = 0
        vim.fn.tempname = function()
          serial = serial + 1
          return root .. '/fixture-' .. serial
        end
        Helpers = { async_errors = {}, expected_errmsg = {} }
        -- 同步 RPC 直接传播断言；调度回调收集错误，结束时由父进程断言
        local schedule = vim.schedule
        vim.schedule = function(callback)
          schedule(function()
            local ok, err = xpcall(callback, debug.traceback)
            if not ok then Helpers.async_errors[#Helpers.async_errors + 1] = tostring(err) end
          end)
        end
        vim.v.errmsg = ''
      ]])
      end,
      post_case = function()
        local ok, err = pcall(function()
          if not child.is_running() then
            return
          end
          local errors = child.lua_get('Helpers.async_errors')
          assert(#errors == 0, '异步回调异常：' .. table.concat(errors, '\n'))
          local message = child.v.errmsg
          local allowed = child.lua_get('Helpers.expected_errmsg')
          assert(message == '' or vim.tbl_contains(allowed, message), '非预期 Neovim 错误：' .. message)
        end)
        local stopped, stop_err = pcall(child.stop)
        if root then
          vim.fn.delete(root, 'rf')
        end
        assert(stopped, stop_err)
        assert(ok, err)
      end,
    },
  })
  return T, child
end

return M
