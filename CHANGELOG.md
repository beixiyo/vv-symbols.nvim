# Changelog

## 0.3.0 - 2026-10-21

### Changed

- `nil` 表示未配置、取默认值，`false` 表示禁用
- `get_config().mouse` 与 `get_config().peek.keys` 在设为 `false` 时保持 `false`，不再展开为逐项 `false` 的表
- 输入类型统一为 `VVSymbolsOpts`，由 `VVSymbolsConfig` 派生
- `peek.open()` 的 `peek` 参数改为必填，不再在内部回退到默认配置

### Breaking

- `panel.state` 改由 `setup(opts, deps)` 的 `deps.state` 注入，默认持久化宽度，不再接受 `panel.state = false`
- setup() 不再返回配置，需要时用 get_config()

### Fixed

- 直接向 `peek.open()` 传入 `peek.keys = false` 时，浮窗内键位改为全部禁用，不再回退为默认键位

## 0.2.0 - 2026-10-04

### 新增

- LSP 位置请求新增延迟 150ms 的等待帧，`locations()` 可用 `loading_target`（`{ buf, get_pos }`）指定落点
- `quickfix.replace_native`（默认 `true`）接管原生 quickfix / loclist 窗口，可设为 `false` 关闭
- 新增 `mouse.goto_definition` / `mouse.underline`
- `locations.include_declaration` 单独控制位置列表与 `peek()` 引用请求是否包含声明，默认 `nil` 跟随 `references.include_declaration`

### 变更

- `VVSymbolsPreview` 默认链接 `CurSearch` 跟随主题

### Fixed

- 焦点在非文件窗口时，同 tab 可见的非浮动文件窗也显示引用计数
- 位置 / 诊断列表计数不再包含文件分组标题

## 0.1.1 - 2026-09-30

### 新增

- 新增 `peek()` / `:VVSymbolsPeek` 只读浮窗预览，支持多结果循环切换、确认跳转与关闭，保留 jumplist / tagstack 语义
- 新增 `lens.callable_only` 与 `references.start` 的同名参数：默认 `false` 为所有导出符号计数，设为 `true` 回到仅可调用符号

### Fixed

- 无导出识别语言的顶层计数豁免仅适用于可调用符号，`callable_only = false` 不再误纳入标题等非可调用符号

## 0.1.0 - 2026-09-18
