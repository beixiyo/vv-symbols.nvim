-- 位置列表控制器：拥有查询、诊断订阅和失效处理，展示交给面板
local Locations = require('vv-symbols.locations')
local Lsp = require('vv-symbols.lsp')
local Async = require('vv-utils.async')
local Path = require('vv-utils.path')
local M = {}
local Lists = {}
Lists.__index = Lists
local namespace = vim.api.nvim_create_namespace('vv-symbols.locations')

local lsp_location_kinds = {
  references = true,
  definition = true,
  declaration = true,
  implementation = true,
  type_definition = true,
}

local function valid_buffer(buf) return type(buf) == 'number' and vim.api.nvim_buf_is_valid(buf) end

local function loaded_buffer(buf) return valid_buffer(buf) and vim.api.nvim_buf_is_loaded(buf) end

local function source_error(buf)
  if not valid_buffer(buf) then return 'Source buffer was closed' end
  if not vim.api.nvim_buf_is_loaded(buf) then return 'Source buffer was unloaded' end
end

local function canonical_root(buf)
  local root = valid_buffer(buf) and Path.get_root(buf) or Path.get_cwd()
  return vim.uv.fs_realpath(root) or root
end

local function clear_cursor_mark(ctx)
  if ctx.cursor_mark and valid_buffer(ctx.buf) then
    pcall(vim.api.nvim_buf_del_extmark, ctx.buf, namespace, ctx.cursor_mark)
  end
  ctx.cursor_mark = nil
end

local function track_cursor(ctx)
  if not lsp_location_kinds[ctx.kind] or not loaded_buffer(ctx.buf) then return end
  local cursor = ctx.cursor
  if type(cursor) ~= 'table' then return end
  local line = math.max(0, math.floor(tonumber(cursor.line) or 0))
  local lines = vim.api.nvim_buf_get_lines(ctx.buf, line, line + 1, false)
  if #lines == 0 then return end
  local byte_col = math.max(0, math.min(#lines[1], math.floor(tonumber(cursor.byte_col) or 0)))
  local ok, mark = pcall(vim.api.nvim_buf_set_extmark, ctx.buf, namespace, line, byte_col, {
    right_gravity = true,
  })
  if ok then ctx.cursor_mark = mark end
end

local function current_cursor(ctx)
  local err = source_error(ctx.buf)
  if err then return nil, err end
  if not ctx.cursor_mark then return nil, 'Source cursor mark is unavailable' end
  local ok, position = pcall(vim.api.nvim_buf_get_extmark_by_id, ctx.buf, namespace, ctx.cursor_mark, {})
  if not ok or type(position) ~= 'table' or #position < 2 then
    return nil, 'Source cursor mark is no longer available'
  end
  return { line = position[1], byte_col = position[2] }
end

---创建与面板生命周期绑定的列表控制器
function M.new(opts) return setmetatable({ view = opts.view, config = opts.config }, Lists) end

---取消查询和事件；晚到响应不能恢复旧列表
function Lists:stop()
  if self.scope then
    self.scope:dispose()
    self.scope = nil
  end
  if self.context then clear_cursor_mark(self.context) end
  if self.group then
    vim.api.nvim_del_augroup_by_id(self.group)
    self.group = nil
  end
  self.context = nil
end

local titles = {
  references = 'References',
  definition = 'Definitions',
  declaration = 'Declarations',
  implementation = 'Implementations',
  type_definition = 'Type definitions',
  diagnostics = 'Diagnostics',
  quickfix = 'Quickfix',
  loclist = 'Location list',
}

function Lists:publish(items, err, loading)
  local ctx = self.context
  if not ctx then return end
  if not ctx.presented and lsp_location_kinds[ctx.kind] and loading then return end
  local nodes = Locations.build({
    items = items or {},
    kind = ctx.kind == 'diagnostics' and 'Diagnostic' or 'Reference',
    root = ctx.root,
  })
  if lsp_location_kinds[ctx.kind] and not loading and not err and #nodes == 0 then
    self:stop()
    if self.view.reference_mode then self.view:close() end
    return
  end
  if ctx.awaiting_single then
    ctx.awaiting_single = false
    if not err and #nodes == 1 and #nodes[1].children == 1 then
      if self.view:jump_single(nodes[1].children[1], ctx.source_win) then
        self:stop()
        return
      end
    end
  end
  local first_presentation = not ctx.presented
  if first_presentation then
    ctx.presented = true
    if self.view.begin_list then self.view:begin_list(ctx.return_context) end
  end
  self.view:show({
    buf = ctx.buf,
    title = titles[ctx.kind],
    mode = ctx.kind,
    nodes = nodes,
    results = {},
    status = loading and 'loading' or err and 'error' or 'ready',
    error = err,
  })
  if first_presentation then self.view:open() end
end

---按当前上下文重新采集；LSP 位置取自打开列表时的源码光标
function Lists:refresh()
  local ctx = self.context
  if not ctx then return end
  self.scope:cancel()
  if ctx.stale and lsp_location_kinds[ctx.kind] then
    local cursor, err = current_cursor(ctx)
    if err then
      self:publish({}, err)
      return
    end
    ctx.cursor = cursor
    ctx.stale = nil
  elseif ctx.stale then
    self:publish({}, ctx.stale)
    return
  end
  if ctx.kind == 'diagnostics' then
    local items = {}
    for _, d in ipairs(vim.diagnostic.get(ctx.filter_buf, ctx.severity and { severity = ctx.severity } or nil)) do
      items[#items + 1] = {
        uri = vim.uri_from_bufnr(d.bufnr),
        encoding = 'utf-8',
        message = d.message,
        severity = d.severity,
        source = d.source,
        range = {
          start = { line = d.lnum, character = d.col },
          ['end'] = { line = d.end_lnum or d.lnum, character = d.end_col or d.col },
        },
      }
    end
    self:publish(items)
  elseif ctx.kind == 'quickfix' or ctx.kind == 'loclist' then
    if ctx.kind == 'loclist' and (type(ctx.win) ~= 'number' or not vim.api.nvim_win_is_valid(ctx.win)) then
      self:publish({}, 'Location list window was closed')
      return
    end
    local entries = ctx.kind == 'quickfix' and vim.fn.getqflist() or vim.fn.getloclist(ctx.win)
    local items = {}
    for _, item in ipairs(entries) do
      if item.valid == 1 and item.bufnr > 0 and item.lnum > 0 then
        items[#items + 1] = {
          uri = vim.uri_from_bufnr(item.bufnr),
          encoding = 'utf-8',
          message = item.text,
          range = {
            start = { line = item.lnum - 1, character = math.max(0, item.col - 1) },
            ['end'] = {
              line = math.max(item.lnum, item.end_lnum or 0) - 1,
              character = math.max(item.col, item.end_col or 0),
            },
          },
        }
      end
    end
    self:publish(items)
  else
    if not vim.api.nvim_buf_is_valid(ctx.buf) then
      self:publish({}, 'Source buffer closed')
      return
    end
    local tick = vim.api.nvim_buf_get_changedtick(ctx.buf)
    local request = self.scope:begin()
    self:publish({}, nil, true)
    local cancel = Lsp.locations({
      buf = ctx.buf,
      method = ctx.kind,
      cursor = ctx.cursor,
      client_id = ctx.client_id,
      timeout_ms = self.config.timing.timeout_ms,
      include_declaration = self.config.references.include_declaration,
    }, function(err, result)
      if not request:finish() or self.context ~= ctx then return end
      if not vim.api.nvim_buf_is_valid(ctx.buf) or vim.api.nvim_buf_get_changedtick(ctx.buf) ~= tick then
        ctx.stale = 'Source changed; press r to refresh'
        self:publish({}, ctx.stale)
        return
      end
      local items = {}
      ctx.uris = {}
      for _, location in ipairs(result and result.locations or {}) do
        ctx.uris[location.uri] = true
        items[#items + 1] = vim.tbl_extend('force', location, { encoding = result.encoding })
      end
      self:publish(items, err and tostring(err))
    end)
    request:set_cancel(cancel)
  end
end

---打开列表并订阅相关数据变化
function Lists:open(ctx)
  self:stop()
  ctx.root = canonical_root(ctx.buf)
  self.context = ctx
  ctx.awaiting_single = lsp_location_kinds[ctx.kind]
      and self.config.locations
      and self.config.locations.jump_single_result
    or false
  self.scope = Async.scope({ cancel_previous = true })
  track_cursor(ctx)
  self.group = vim.api.nvim_create_augroup('VVSymbolsLists', { clear = true })
  vim.api.nvim_create_autocmd({ 'DiagnosticChanged', 'QuickFixCmdPost' }, {
    group = self.group,
    callback = function(ev)
      if
        ev.event == 'DiagnosticChanged' and ctx.kind == 'diagnostics'
        or ev.event == 'QuickFixCmdPost' and (ctx.kind == 'quickfix' or ctx.kind == 'loclist')
      then
        vim.schedule(function()
          if self.context == ctx then self:refresh() end
        end)
      end
    end,
  })
  vim.api.nvim_create_autocmd({ 'TextChanged', 'TextChangedI', 'BufWritePost', 'BufUnload', 'BufWipeout' }, {
    group = self.group,
    callback = function(ev)
      if ctx.kind == 'diagnostics' or ctx.kind == 'quickfix' or ctx.kind == 'loclist' then return end
      if ev.buf == ctx.buf then
        local error_message = ev.event == 'BufUnload' and 'Source buffer was unloaded'
          or ev.event == 'BufWipeout' and 'Source buffer was closed'
          or source_error(ctx.buf)
        if error_message then
          self.scope:cancel()
          ctx.stale = error_message
          self:publish({}, error_message)
          return
        end
      end
      local ok_uri, uri = pcall(vim.uri_from_bufnr, ev.buf)
      if ev.buf == ctx.buf or ok_uri and ctx.uris and ctx.uris[uri] then
        self.scope:cancel()
        ctx.stale = 'Source changed; press r to refresh'
        self:publish({}, ctx.stale)
      end
    end,
  })
  self:refresh()
end

return M
