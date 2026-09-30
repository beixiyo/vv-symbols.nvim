# Changelog

## 0.1.1 - 2026-09-30

### 新增

- `peek()` / `:VVSymbolsPeek`：浮窗预览光标符号的 LSP 位置；目标文件以只读快照展示，多结果在浮窗内 `]p` / `[p` 环形切换，`Enter` 确认跳转并保留 jumplist/tagstack 语义，`q` / `Esc` 关闭
- `lens.callable_only`（默认 `false`）：默认所有导出符号（含变量/常量）显示引用计数并纳入自动查询；设为 `true` 回到仅函数等可调用符号。`references.start` 相应新增 `callable_only` 参数

### Fixed

- `callable_only=false` 时，无导出识别语言的顶层非可调用符号（markdown 标题等）不得再凭「导出未知」豁免进入引用计数；该豁免始终仅对顶层可调用符号生效

## 0.1.0 - 2026-09-18

