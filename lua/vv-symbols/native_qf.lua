-- 原生 quickfix / loclist 窗口接管：检测原生窗口出现后关闭它，回到所属代码窗口，交由调用方打开替代面板
-- 只负责检测与窗口切换；打开什么由 attach 的 open 回调决定。vv-symbols 自己的列表面板是 nofile 树，不会触发本接管
local M = {}

local AUGROUP = 'VVSymbolsNativeQuickfix'
local attachment

---@param win integer
---@return boolean quickfix 是否为原生 quickfix/loclist 窗口
---@return boolean loclist 是否为 loclist 窗口
local function classify(win)
  if not vim.api.nvim_win_is_valid(win) then return false, false end
  local info = vim.fn.getwininfo(win)[1]
  return info ~= nil and info.quickfix == 1, info ~= nil and info.loclist == 1
end

---原生窗口所属代码窗口：loclist 取其 filewinid，quickfix 取进入前的上一个窗口；无效或本身是 quickfix 时不接管
---@param win integer
---@param loclist boolean
---@return integer?
local function owner_window(win, loclist)
  local owner
  if loclist then
    owner = vim.fn.getloclist(win, { filewinid = 0 }).filewinid
  else
    owner = vim.fn.win_getid(vim.fn.winnr('#'))
  end
  if type(owner) ~= 'number' or owner <= 0 or owner == win or not vim.api.nvim_win_is_valid(owner) then return end
  if classify(owner) then return end
  return owner
end

---启用接管，幂等；重复调用以最新 open 回调为准
---@param opts VVSymbolsNativeQfOpts
function M.attach(opts)
  local current = {}
  attachment = current
  local group = vim.api.nvim_create_augroup(AUGROUP, { clear = true })

  vim.api.nvim_create_autocmd('BufWinEnter', {
    group = group,
    callback = function()
      local qf_win = vim.api.nvim_get_current_win()
      local quickfix, loclist = classify(qf_win)
      if not quickfix then return end
      local owner_win = owner_window(qf_win, loclist)
      if not owner_win then return end
      local qf_buf = vim.api.nvim_win_get_buf(qf_win)
      local owner_buf = vim.api.nvim_win_get_buf(owner_win)

      -- 推迟到 :copen / :lopen 完成后再关窗；期间窗口或 buffer 有变化说明已被别处接手，放弃接管
      vim.schedule(function()
        if attachment ~= current then return end
        local still_quickfix, still_loclist = classify(qf_win)
        if
          not still_quickfix
          or still_loclist ~= loclist
          or vim.api.nvim_win_get_buf(qf_win) ~= qf_buf
          or not vim.api.nvim_win_is_valid(owner_win)
          or vim.api.nvim_win_get_buf(owner_win) ~= owner_buf
        then
          return
        end

        vim.api.nvim_win_close(qf_win, true)
        -- close / 切焦点可同步触发用户 autocmd；每次 UI 副作用之后仍须确认 attach 未失效
        if attachment ~= current or not vim.api.nvim_win_is_valid(owner_win) then return end
        vim.api.nvim_set_current_win(owner_win)
        if attachment ~= current then return end
        opts.open({ kind = loclist and 'loclist' or 'quickfix', win = owner_win })
      end)
    end,
  })
end

---停止接管，幂等
function M.detach()
  attachment = nil
  pcall(vim.api.nvim_del_augroup_by_name, AUGROUP)
end

return M

---@class VVSymbolsNativeQfOpts
---@field open fun(ctx:VVSymbolsNativeQfContext) 原生窗口已关闭且焦点回到所属代码窗口后调用，负责打开替代面板

---@class VVSymbolsNativeQfContext
---@field kind 'quickfix'|'loclist' 被接管的原生窗口类型
---@field win integer 所属代码窗口
