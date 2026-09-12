-- LSP 位置预览适配：复用共享文件预览的保存/恢复，负责字符编码与落点高亮
local FilePreview = require('vv-utils.tree_panel.preview')
local M = {}
local Preview = {}
Preview.__index = Preview
local namespace = vim.api.nvim_create_namespace('vv-symbols.preview')

---创建固定源码窗口的预览会话；首次移动前保存文件、光标与视口
function M.new(win) return setmetatable({ source_win = win, file = FilePreview.new(win) }, Preview) end

local function clear_highlight(self)
  if self.highlight_buf and vim.api.nvim_buf_is_valid(self.highlight_buf) then
    vim.api.nvim_buf_clear_namespace(self.highlight_buf, namespace, 0, -1)
  end
  self.highlight_buf = nil
end

local function location(node)
  if not node or not node.uri or not node.selection_range then return end
  local buf = vim.uri_to_bufnr(node.uri)
  vim.fn.bufload(buf)
  local range = node.selection_range
  local row = math.min(range.start.line, vim.api.nvim_buf_line_count(buf) - 1)
  local line = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or ''
  local col = vim.str_byteindex(line, node.encoding or 'utf-16', range.start.character, false)
  return { file = vim.uri_to_fname(node.uri), row = row + 1, col = col }, buf
end

---预览并标出选中位置，不转移焦点、不修改文本
function Preview:show(node)
  if not vim.api.nvim_win_is_valid(self.source_win) then return end
  local target, buf = location(node)
  if not target then return end
  clear_highlight(self)
  self.file:show(target)
  vim.api.nvim_win_call(self.source_win, function() vim.cmd('normal! zvzz') end)
  self.highlight_buf = buf
  local finish = node.selection_range['end']
  local last = math.min(finish.line, vim.api.nvim_buf_line_count(buf) - 1)
  local text = vim.api.nvim_buf_get_lines(buf, last, last + 1, false)[1] or ''
  local last_col = vim.str_byteindex(text, node.encoding or 'utf-16', finish.character, false)
  vim.api.nvim_buf_set_extmark(buf, namespace, target.row - 1, 0, {
    line_hl_group = 'CursorLine',
    priority = 150,
  })
  if last > target.row - 1 or last_col > target.col then
    vim.api.nvim_buf_set_extmark(buf, namespace, target.row - 1, target.col, {
      end_row = last,
      end_col = last_col,
      hl_group = 'VVSymbolsPreview',
      priority = 160,
    })
  end
end

---确认位置并进入源码；之后关闭面板不能撤销这次跳转
function Preview:commit(node)
  local target = location(node)
  if not target or not vim.api.nvim_win_is_valid(self.source_win) then return false end
  -- 从原始位置确认跳转，保留 Neovim 的 jumplist/tagstack 和 listed buffer 语义
  self:restore()
  vim.api.nvim_set_current_win(self.source_win)
  return vim.lsp.util.show_document(
    { uri = node.uri, range = node.selection_range },
    node.encoding or 'utf-16',
    { focus = true }
  )
end

---撤销预览；focus 默认 false，退出侧栏时由调用方显式传 true
function Preview:restore(opts)
  local current = vim.api.nvim_win_is_valid(self.source_win) and vim.api.nvim_win_get_buf(self.source_win)
  local owned = current == (self.highlight_buf or self.file.original_buf)
  clear_highlight(self)
  -- 用户主动在源码窗口换了文件时，不把外部切换误当作本次临时预览撤销
  if owned then self.file:restore() end
  if
    opts
    and opts.focus
    and vim.api.nvim_win_is_valid(self.source_win)
    and vim.api.nvim_win_get_tabpage(self.source_win) == vim.api.nvim_get_current_tabpage()
  then
    vim.api.nvim_set_current_win(self.source_win)
  end
end

return M
