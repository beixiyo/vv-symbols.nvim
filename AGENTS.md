# vv-symbols.nvim

- `model.lua`：LSP 数据归一化、可调用类型补充与纯过滤
- `exports.lua`：基于 Tree-sitter 的 JS/TS/TSX 模块导出 API 标注
- `lsp.lua`：单次客户端请求、物理取消、超时与位置去重
- `references.lua`：有界队列与引用结果状态
- `lens.lua`：自有 namespace 的虚拟行
- `locations.lua`：LSP、诊断、quickfix、loclist 位置按文件分组与源码预览
- `lists.lua`：位置列表请求、订阅与生命周期
- `render.lua`：符号和位置行的 tree_panel 渲染与语法高亮
- `panel.lua`：树与输入交互，不发送 LSP 请求
- `navigation.lua`：结果级导航、折叠分组与方向键进入策略
- `preview.lua`：LSP 位置编码、跨文件预览、确认跳转和取消恢复
- `init.lua`：公共 API、当前文档会话、事件与资源所有权
- `config.lua`：公共默认值和边界归一化

只使用一个符号客户端完成同文档的引用查询。请求失败/索引未知不能显示为零引用
窗口刷新不能写回初始宽度；不得在插件内部硬编码 vv-splits、vv-scrollbar、Trouble 或全局补全行为

运行 `sh tests/run.sh`。涉及焦点、输入、缩放与首行虚拟行时，还要在完整配置的 TUI 中验证
