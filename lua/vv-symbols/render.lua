-- vv-symbols.render — tree_panel 的符号和位置行渲染
--
-- 位置节点的 code 已由 locations 模型读取；这里仅负责语法 chunks 和
-- 引用范围叠加，不为了预览创建或加载 buffer

local Tree = require('vv-utils.tree_panel')
local Path = require('vv-utils.path')
local Lens = require('vv-symbols.lens')

local M = {}

local ok_icons, icons = pcall(require, 'vv-icons')
local ui_icons = ok_icons and icons.raw.ui or {}
local CHEVRON_OPEN = (ui_icons.fold_open and ui_icons.fold_open.glyph or '') .. ' '
local CHEVRON_CLOSED = (ui_icons.fold_closed and ui_icons.fold_closed.glyph or '') .. ' '
local RANGE_HL = 'VVSymbolsReferenceMatch'
local DIAGNOSTIC_HL = {
  Error = 'DiagnosticError',
  Warn = 'DiagnosticWarn',
  Info = 'DiagnosticInfo',
  Hint = 'DiagnosticHint',
}
local SEVERITY_KIND = {
  [1] = 'Error',
  [2] = 'Warn',
  [3] = 'Info',
  [4] = 'Hint',
  error = 'Error',
  warning = 'Warn',
  warn = 'Warn',
  information = 'Info',
  info = 'Info',
  hint = 'Hint',
}

local function clean(value) return tostring(value or ''):gsub('[\r\n\t]', ' ') end

local function symbol_hl(kind)
  if kind == 'Function' or kind == 'Method' or kind == 'Constructor' then return '@function' end
  if
    kind == 'Class'
    or kind == 'Interface'
    or kind == 'Struct'
    or kind == 'Enum'
    or kind == 'TypeParameter'
    or kind == 'Namespace'
    or kind == 'Module'
  then
    return '@type'
  end
  if kind == 'Variable' or kind == 'Constant' or kind == 'Property' or kind == 'Field' or kind == 'EnumMember' then
    return '@variable'
  end
  return 'Normal'
end

local function syntax_chunks(code, lang)
  local ok, chunks = pcall(Tree.syntax_chunks, code, lang, 'Normal')
  if ok and type(chunks) == 'table' and #chunks > 0 then return chunks end
  return { { code, 'Normal' } }
end

local function diagnostic_hl(node)
  local kind = DIAGNOSTIC_HL[node.kind]
  if kind then return kind end
  local severity = node.severity
  if type(severity) == 'string' then severity = severity:lower() end
  local severity_kind = SEVERITY_KIND[severity]
  return DIAGNOSTIC_HL[severity_kind] or 'Comment'
end

local function append_chunk(result, text, hl)
  if text == '' then return end
  local previous = result[#result]
  if previous and previous[2] == hl then
    previous[1] = previous[1] .. text
  else
    result[#result + 1] = { text, hl }
  end
end

--- Overlay one byte range on syntax chunks without losing captures around it.
---@param chunks table[]
---@param start_col integer
---@param end_col integer
---@return table[]
local function overlay_range(chunks, start_col, end_col)
  if end_col <= start_col then return chunks end
  local result, offset = {}, 0
  for _, chunk in ipairs(chunks) do
    local text, hl = tostring(chunk[1] or ''), chunk[2]
    local chunk_start, chunk_end = offset, offset + #text
    local cursor = 1
    local left = math.max(start_col, chunk_start)
    local right = math.min(end_col, chunk_end)
    if right > left then
      local before = left - chunk_start
      local marked = right - left
      append_chunk(result, text:sub(cursor, before), hl)
      append_chunk(result, text:sub(before + 1, before + marked), { hl, RANGE_HL })
      append_chunk(result, text:sub(before + marked + 1), hl)
    else
      append_chunk(result, text, hl)
    end
    offset = chunk_end
  end
  return result
end

local function panel_width(ctx)
  local panel = ctx.panel
  if not panel or type(panel.get_width) ~= 'function' then return end
  local ok, width = pcall(panel.get_width, panel)
  return ok and tonumber(width) or nil
end

local function display_path(path, available)
  path = Path.norm(path)
  local candidate = Path.collapse_middle(path, { head = 1, tail = 3 })
  if available and vim.fn.strdisplaywidth(candidate) > available then
    candidate = Path.collapse_middle(path, { head = 1, tail = 2 })
  end
  if available and vim.fn.strdisplaywidth(candidate) > available then
    candidate = Path.collapse_middle(path, { head = 1, tail = 1 })
  end
  if available and vim.fn.strdisplaywidth(candidate) > available then
    candidate = Path.collapse_middle(path, { head = 0, tail = 1 })
  end
  return candidate
end

--- Render the source path with the same width-aware compression as file groups.
function M.source_path(opts)
  if not opts.buf or not vim.api.nvim_buf_is_valid(opts.buf) then return '' end
  local path = vim.api.nvim_buf_get_name(opts.buf)
  path = Path.norm(vim.uv.fs_realpath(path) or path)
  local root = Path.get_root(opts.buf)
  root = Path.norm(vim.uv.fs_realpath(root) or root):gsub('/+$', '') .. '/'
  if path:sub(1, #root) == root then path = path:sub(#root + 1) end
  return clean(display_path(path, opts.width))
end

local function render_file(ctx, node)
  local indent = string.rep('  ', ctx.depth or 0)
  local marker = ctx.folded and CHEVRON_CLOSED or CHEVRON_OPEN
  local count = #(node.children or {})
  local width = panel_width(ctx)
  local available = width and (width - vim.fn.strdisplaywidth(indent .. marker .. ('  (%d)'):format(count)) - 1)
  local path = display_path(tostring(node.display_path or node.label or node.name or ''), available)
  return {
    chunks = {
      { indent .. marker, 'Comment' },
      { clean(path), 'Directory' },
      { '  (', 'Comment' },
      { tostring(count), count == 0 and 'VVSymbolsZeroReferences' or 'VVSymbolsReferenceCount' },
      { ')', 'Comment' },
    },
  }
end

local function render_location(ctx, node)
  local line_number = node.lnum and ('%d │ '):format(node.lnum) or ''
  local code = tostring(node.code or '')
  -- Trim only the display; source coordinates remain intact for preview and jumps.
  local removed = #(code:match('^%s*') or '')
  local chunks = overlay_range(
    syntax_chunks(vim.trim(code), node.lang),
    (node.byte_col or 0) - removed,
    (node.byte_end_col or 0) - removed
  )
  local output = {
    { line_number, 'LineNr' },
  }
  for _, chunk in ipairs(chunks) do
    output[#output + 1] = chunk
  end
  if node.message and node.message ~= '' then
    output[#output + 1] = { '  ' .. clean(node.message), diagnostic_hl(node) }
  end
  return { chunks = output }
end

local function render_symbol(ctx, node)
  local indent = string.rep('  ', ctx.depth or 0)
  local marker = ctx.has_children and (ctx.folded and CHEVRON_CLOSED or CHEVRON_OPEN) or '  '
  local chunks = {
    { indent .. marker, 'Comment' },
    { clean(node.label or node.name), node.context_only and 'Comment' or symbol_hl(node.kind) },
    { '  ' .. clean(node.kind), 'Comment' },
  }
  -- The symbols panel may provide the asynchronous lens result in the
  -- context; accepting it here keeps this renderer independent of the view.
  local result = ctx.result or node.result
  local label = clean(ctx.refs_label or 'refs')
  if result then
    local counted = Lens.count_chunks(result, label)
    if counted then
      chunks[#chunks + 1] = { '  ', 'VVSymbolsLens' }
      vim.list_extend(chunks, counted)
    else
      local suffix = result.status == 'pending' and ('  … ' .. label) or result.status == 'error' and ('  ? ' .. label) or ''
      if suffix ~= '' then chunks[#chunks + 1] = { suffix, 'VVSymbolsLens' } end
    end
  end
  return { chunks = chunks }
end

--- Render a node for `vv-utils.tree_panel`.
---@param ctx VVTreePanelRenderContext
---@return VVTreePanelRenderRow
function M.node(ctx)
  local node = ctx.node or {}
  if node.file_group then return render_file(ctx, node) end
  if node.code ~= nil or node.lnum ~= nil then return render_location(ctx, node) end
  return render_symbol(ctx, node)
end

return M
