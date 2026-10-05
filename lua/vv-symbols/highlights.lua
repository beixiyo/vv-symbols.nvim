-- 高亮组注册：全部链接标准组，颜色由主题决定
-- 以 default=true 写入，用户或主题预先定义的值优先；ColorScheme 后由 vv-utils.hl 重新挂载
local Hl = require('vv-utils.hl')

local M = {}

local AUGROUP = 'VVSymbolsHighlights'

---注册全部高亮组并订阅 ColorScheme，幂等
function M.attach()
  Hl.register(AUGROUP, {
    -- 列表预览与 peek 的落点
    VVSymbolsPreview = { link = 'CurSearch' },
    VVSymbolsName = { link = 'Normal' },
    VVSymbolsKind = { link = 'Type' },
    VVSymbolsLens = { link = 'Comment' },
    VVSymbolsReferenceIcon = { link = 'Special' },
    -- 列表内引用范围不再加视觉标记（落点高亮只保留在 preview 侧）
    VVSymbolsReferenceMatch = {},
    VVSymbolsReferenceCount = { link = 'VVSymbolsReferenceIcon' },
    VVSymbolsZeroReferences = { link = 'DiagnosticError' },
    -- 按住 Ctrl 悬停时可跳转定义的标识符
    VVSymbolsLink = { link = 'Underlined' },
  })
end

---取消 ColorScheme 订阅，已写入的高亮保留；幂等
function M.detach()
  pcall(vim.api.nvim_del_augroup_by_name, AUGROUP)
end

return M
