# vv-symbols.nvim

- `model.lua`：LSP 数据归一化、可调用类型补充与纯过滤
- `exports.lua`：基于 Tree-sitter 的 JS/TS/TSX 模块导出 API 标注
- `lsp.lua`：单次客户端请求、物理取消、超时与位置去重
- `references.lua`：有界队列与引用结果状态
- `lens.lua`：自有 namespace 的虚拟行
- `locations.lua`：LSP、诊断、quickfix、loclist 位置按文件分组与源码预览
- `lists.lua`：位置列表请求、订阅与生命周期
- `loading.lua`：LSP 等待帧落点（源码光标标识符末尾或调用方锚点）
- `render.lua`：符号和位置行的 tree_panel 渲染与语法高亮
- `panel.lua`：树与输入交互，不发送 LSP 请求
- `navigation.lua`：结果级导航、折叠分组与方向键进入策略
- `preview.lua`：LSP 位置编码、跨文件预览、确认跳转和取消恢复
- `peek.lua`：LSP 位置浮窗预览的会话编排（请求、多结果切换、标题、底部按键提示与确认跳转）；浮窗机制由 `vv-utils.ui_peek` 提供
- `native_qf.lua`：原生 quickfix / loclist 窗口检测与接管（关闭原生窗口、回到所属代码窗口，打开什么由回调决定）
- `mouse.lua`：Ctrl+左键定义跳转与 Ctrl 悬停下划线（全局鼠标映射所有权、extmark、仅下划线可见期间的 on_key 订阅、`mousemoveevent` 开关）；跳转动作由 init 回调注入
- `highlights.lua`：高亮组注册（全部 `default = true` 链接标准组，颜色由主题决定）
- `init.lua`：公共 API、当前文档会话、事件与资源所有权
- `config.lua`：公共默认值和边界归一化

只使用一个符号客户端完成同文档的引用查询。请求失败/索引未知不能显示为零引用
窗口刷新不能写回初始宽度；不得在插件内部硬编码 vv-splits、vv-scrollbar、Trouble 或全局补全行为

运行 `sh tests/run.sh`。涉及焦点、输入、缩放与首行虚拟行时，还要在完整配置的 TUI 中验证
