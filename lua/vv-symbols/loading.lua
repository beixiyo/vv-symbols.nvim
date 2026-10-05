-- vv-symbols.loading — LSP 位置等待期间的 loading 帧落点
--
-- 默认落点是源码光标所在标识符末尾（inline，不用 eol：代码行长且不折行会被截掉）；
-- 调用方也可传入自己的 { buf, get_pos } 锚点。所有帧延迟 150ms 出现，快速返回不闪
local Loading = require('vv-utils.loading')

local M = {}

local DELAY_MS = 150

---光标所在标识符结束字节相对光标的偏移；按源码 buffer 自己的 iskeyword 判断，不在词上时为 0
---@param buf integer
---@param cursor {line:integer,byte_col:integer}
---@return integer
local function word_end_offset(buf, cursor)
  local text = vim.api.nvim_buf_get_lines(buf, cursor.line, cursor.line + 1, false)[1] or ''
  local finish = vim.api.nvim_buf_call(buf, function() return vim.fn.matchend(text, [[\k*]], cursor.byte_col) end)
  return math.max(0, finish - cursor.byte_col)
end

---源码光标标识符末尾的锚点；cursor 每帧调用，返回 nil 时隐藏
---文本变化会让等待中的请求失效，因此词尾偏移只在创建时计算一次
---@param buf integer
---@param cursor fun(): {line:integer,byte_col:integer}?
---@return VVSymbolsLoadingTarget?
function M.cursor_target(buf, cursor)
  local start = cursor()
  if not start or not vim.api.nvim_buf_is_loaded(buf) then return nil end
  local offset = word_end_offset(buf, start)
  return {
    buf = buf,
    get_pos = function()
      local position = cursor()
      return position and { row = position.line + 1, col = position.byte_col + offset }
    end,
  }
end

---在锚点 inline 显示 loading 帧；返回的 handle 由调用方在请求终结时 stop
---@param target VVSymbolsLoadingTarget
---@return vv-utils.loading.Handle
function M.start(target)
  return Loading.mark({ buf = target.buf, get_pos = target.get_pos, delay_ms = DELAY_MS })
end

return M

---@class VVSymbolsLoadingTarget
---@field buf integer
---@field get_pos fun(): VVLoadingPos? 每帧调用；nil 隐藏
