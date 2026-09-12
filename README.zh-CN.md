<div align="center">
  <h1>vv-symbols.nvim</h1>
  <p><a href="./README.md">English</a> | 中文</p>
  <p>想要我的 Neovim 配置？查看 <a href="https://github.com/beixiyo/dotfiles">dotfiles</a></p>
  <em>基于 LSP 的符号树、引用计数与位置列表</em>
  <p>
    <img src="https://img.shields.io/badge/Neovim-0.12+-57A143?style=flat-square&logo=neovim&logoColor=white" alt="Neovim 0.12+" />
    <img src="https://img.shields.io/badge/Lua-2C2D72?style=flat-square&logo=lua&logoColor=white" alt="Lua" />
  </p>
</div>

## 为什么替代 Trouble

- Trouble 连续调整窗口大小会卡住，需要切换窗口才能恢复
- 缺少按名称、路径和符号类型交互筛选的完整流程
- 无法直接在源码中查看函数引用数量

vv-symbols 将符号、引用、定义、实现、诊断、quickfix 和 loclist 整合到同一个侧栏，不依赖 Trouble

## 功能

- 符号树支持名称与类型筛选，可快速切换为仅显示函数
- 位置列表按文件分组，自动压缩长路径、去除代码两侧空白，保留 Tree-sitter 语法高亮
- 移动列表光标实时预览源码，确认跳转或退出时恢复原位置
- 源码中显示引用数量，可放在符号上方或行末；默认只显示导出的函数
- 固定底部快捷键提示，支持方向键、折叠操作和 `g?` 帮助

## 安装与配置

要求 Neovim 0.12+、`vv-utils.nvim` 和对应语言的 LSP。源码高亮需要对应的 Tree-sitter parser；Lua 文档注释还需要 `luadoc` parser 与查询文件

在 LazyVim 的 `lua/plugins/` 中添加文件，或将以下声明放入 lazy.nvim 的插件列表。当前使用本地插件目录：

```lua
return {
  {
    dir = vim.fn.expand('~/.config/nvim/vendors/vv-symbols.nvim'),
    name = 'vv-symbols.nvim',
    dependencies = {
      'beixiyo/vv-utils.nvim',
      'beixiyo/vv-icons.nvim', -- 可选，统一图标风格
    },
    opts = {
      panel = {
        width = 42,           -- 初始宽度，手动 resize 后保留新宽度
        position = 'left',    -- 'left' / 'right'
        preview = true,       -- 移动光标时预览源码
        state = false,        -- 可传入 vv-utils.state handle 持久化宽度
      },
      filter = {
        mode = 'subseq',      -- 子序列；也支持 'fixed' 子串、'regex' 正则
        kinds = false,       -- 不限制类型；如 { 'Function' } 仅显示函数
        debounce_ms = 150,    -- 输入筛选防抖
      },
      lens = {
        enabled = true,      -- 显示引用计数；关闭后停止自动引用查询
        scope = 'exported',  -- 'exported' / 'all'；导出识别支持 JS/TS/TSX
        position = 'above',  -- 'above' 符号上方 / 'eol' 定义行末
        -- filter = function(node) return node.name ~= 'internal' end,
        -- filter 在 scope 之后追加筛选；其他语言可搭配 scope = 'all'
      },
      locations = {
        jump_single_result = true, -- 单个定义/引用/实现等直接跳转；零结果静默结束
      },
      references = {
        concurrency = 4,           -- 自动引用查询的最大并发数
        max_symbols = 200,         -- 自动计数的符号上限
        include_declaration = false, -- 引用计数不包含声明位置
      },
      timing = {
        debounce_ms = 250,   -- 源码编辑后重新分析的防抖
        timeout_ms = 3000,   -- LSP 请求超时
      },
      max_lines = 5000,      -- 超过此行数的文件不自动分析
      -- keymaps = { ['/'] = false, s = 'filter' }, -- 覆盖面板键位，false 禁用
    },
    keys = {
      { 'go', '<cmd>VVSymbolsToggle<cr>', desc = '符号树' },
      { 'grr', '<cmd>VVSymbolsReferences<cr>', desc = '引用' },
      { 'gd', function() require('vv-symbols').locations({ method = 'definition' }) end, desc = '定义' },
      { 'gri', function() require('vv-symbols').locations({ method = 'implementation' }) end, desc = '实现' },
      { 'grt', function() require('vv-symbols').locations({ method = 'type_definition' }) end, desc = '类型定义' },
      { '<leader>xx', '<cmd>VVSymbolsDiagnostics<cr>', desc = '工作区诊断' },
    },
  },
}
```

图标与引用数字使用主题的 `Special` 颜色，零引用使用 `DiagnosticError`。`0 references` 表示 LSP 未找到引用，不代表代码可以安全删除；`…` 表示查询中，`?` 表示查询失败或超时

## 面板操作

| 键 | 动作 |
|---|---|
| `j/k`、`↑/↓`、`Ctrl-N/P` | 移动并预览，跳过已展开的文件标题 |
| `h/←` | 折叠当前节点或所属文件 |
| `l/→` | 展开并进入首个结果；在结果上进入源码 |
| `Enter` | 确认跳转，保留侧栏 |
| `gf` | 确认跳转并关闭侧栏 |
| `q/Esc` | 退出；未确认的预览恢复原位置 |
| `Tab` | 切换折叠 |
| `zR/zM` | 全部展开/折叠 |
| `/` | 输入筛选 |
| `t` | 符号树筛选类型；诊断列表筛选严重程度 |
| `F` | 符号树切换仅函数/全部类型 |
| `R` | 查看所选符号的引用 |
| `Backspace` | 从符号树进入引用列表后，返回原符号树 |
| `c` | 清除筛选 |
| `r` | 刷新当前列表 |
| `g?` | 查看当前视图可用的快捷键 |

直接使用 `grr` 打开的列表没有返回上级操作。底部提示与帮助只显示当前视图可用的键位，并跟随自定义映射

## 筛选

符号树匹配符号名；位置列表匹配文件路径、结果代码行和诊断消息，不搜索整个文件。路径匹配时保留该文件的全部结果，否则只保留匹配行；类型或严重程度条件仍然生效

输入框中，`Shift-Tab` 切换匹配模式，`Ctrl-N/P` 移动结果，`Enter` 接受筛选，`Esc` 恢复输入前的查询。非法正则保留上次有效结果；清除筛选后恢复原折叠状态

## 常用命令

| 命令 | 动作 |
|---|---|
| `:VVSymbolsToggle` | 打开/关闭当前文件符号树 |
| `:VVSymbolsReferences` | 查看光标处引用 |
| `:VVSymbolsDiagnostics` | 查看工作区诊断 |
| `:VVSymbolsQuickfix` | 查看 quickfix |
| `:VVSymbolsLoclist` | 查看当前窗口 loclist |
| `:VVSymbolsRefresh` | 刷新列表与引用计数 |
| `:VVSymbolsLensEnable` / `:VVSymbolsLensDisable` | 开启/关闭源码引用提示 |

更多 API 与配置类型见 [config.lua](lua/vv-symbols/config.lua) 和 [init.lua](lua/vv-symbols/init.lua)
