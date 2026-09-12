-- vv-symbols.locations — 将位置结果按文件组织，并补齐源码预览字段
--
-- 这里只负责位置数据和有限的源码读取，不创建 buffer，也不拥有面板状态

local Path = require('vv-utils.path')

local M = {}

local DEFAULT_ENCODING = 'utf-16'

local function copy(value) return vim.deepcopy(value) end

local function normalize_encoding(encoding)
  if encoding == 'utf-8' or encoding == 'utf-16' or encoding == 'utf-32' then return encoding end
  return DEFAULT_ENCODING
end

local function position(value)
  value = type(value) == 'table' and value or {}
  return {
    line = math.max(0, math.floor(tonumber(value.line) or 0)),
    character = math.max(0, math.floor(tonumber(value.character) or 0)),
  }
end

local function location_range(value)
  value = type(value) == 'table' and value or {}
  return {
    start = position(value.start),
    ['end'] = position(value['end']),
  }
end

local function absolute_path(path)
  if path == '' then return '' end
  local ok, result = pcall(vim.fs.normalize, vim.fn.fnamemodify(path, ':p'))
  return ok and result or path
end

local function uri_path(uri)
  if type(uri) ~= 'string' or uri == '' then return '' end
  local ok, path = pcall(vim.uri_to_fname, uri)
  return ok and absolute_path(path) or ''
end

local function loaded_buffer(path)
  if path == '' then return end
  local wanted = Path.norm(path)
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_is_loaded(buf) then
      local name = vim.api.nvim_buf_get_name(buf)
      if name ~= '' and Path.norm(absolute_path(name)) == wanted then return buf end
    end
  end
end

local function filetype(path, buf)
  local value = buf and vim.bo[buf].filetype or ''
  if value == '' and path ~= '' and vim.filetype and vim.filetype.match then
    local ok, detected = pcall(vim.filetype.match, { filename = path })
    if ok then value = detected or '' end
  end

  -- Tree-sitter uses tsx for the filetype names Neovim assigns to React files.
  if value == 'typescriptreact' or value == 'javascriptreact' then return 'tsx' end
  return value ~= '' and value or nil
end

local function source_for(path, cache, max_lines)
  local key = path ~= '' and path or '<missing>'
  if cache[key] then return cache[key] end

  local buf = loaded_buffer(path)
  local source = { buf = buf, lines = {}, lang = filetype(path, buf) }
  if buf then
    source.lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  elseif path ~= '' then
    local ok, lines = pcall(vim.fn.readfile, path, '', max_lines)
    if ok and type(lines) == 'table' then source.lines = lines end
  end
  cache[key] = source
  return source
end

local function diagnostic_kind(severity)
  if type(severity) == 'number' then return ({ [1] = 'Error', [2] = 'Warn', [3] = 'Info', [4] = 'Hint' })[severity] end
  if type(severity) ~= 'string' then return end
  return ({
    error = 'Error',
    warning = 'Warn',
    warn = 'Warn',
    information = 'Info',
    info = 'Info',
    hint = 'Hint',
  })[severity:lower()]
end

local function byte_index(line, encoding, character)
  local ok, result = pcall(vim.str_byteindex, line or '', encoding, character, false)
  if ok and type(result) == 'number' then return math.max(0, math.min(#(line or ''), result)) end
  return math.max(0, math.min(#(line or ''), character or 0))
end

local function relative_path(path, root)
  path = Path.norm(path)
  if type(root) ~= 'string' or root == '' then return path end
  root = Path.norm(absolute_path(root)):gsub('/+$', '')
  if root == '' then return path end
  if path == root then return vim.fs.basename(path) or path end
  local prefix = root .. '/'
  if path:sub(1, #prefix) == prefix then return path:sub(#prefix + 1) end
  return path
end

local function identity_part(value)
  value = tostring(value or '')
  return #value .. ':' .. value
end

local function item_key(uri, range, kind, item)
  local key = table.concat({
    identity_part(uri),
    range.start.line,
    range.start.character,
    range['end'].line,
    range['end'].character,
  }, ':')
  -- Non-empty messages are part of identity: diagnostics and quickfix entries
  -- can point at one range while describing different failures/results.
  if type(item.message) == 'string' and item.message ~= '' then
    key = key
      .. ':'
      .. identity_part(item.message)
      .. ':'
      .. identity_part(item.source)
      .. ':'
      .. tostring(item.severity or '')
  end
  return key
end

local function child_id(file_key, uri, range, kind, item)
  return table.concat({
    'location',
    identity_part(file_key),
    identity_part(uri),
    range.start.line,
    range.start.character,
    range['end'].line,
    range['end'].character,
    kind,
    identity_part(item.message),
    identity_part(item.source),
    tostring(item.severity or ''),
  }, ':')
end

--- Build file-grouped location nodes for the tree panel.
---
--- `items` must contain normalized LSP locations. `range` characters use the
--- item's `encoding`; source text is read only up to the furthest requested
--- line for each unloaded file.
---@param opts? {items?:table[],kind?:string,path?:{head?:integer,tail?:integer,ellipsis?:string},root?:string, max_lines?:integer}
---@return table[] roots
function M.build(opts)
  opts = opts or {}
  local items = type(opts.items) == 'table' and opts.items or {}
  local kind = type(opts.kind) == 'string' and opts.kind ~= '' and opts.kind or 'Reference'
  local configured_max_lines = tonumber(opts.max_lines)
  if configured_max_lines then configured_max_lines = math.max(1, math.floor(configured_max_lines)) end
  local requested_lines = {}
  for _, item in ipairs(items) do
    if type(item) == 'table' and type(item.uri) == 'string' and item.uri ~= '' then
      local path = uri_path(item.uri)
      local key = path ~= '' and path or item.uri
      local range = location_range(item.range)
      requested_lines[key] = math.max(requested_lines[key] or 0, range.start.line + 1, range['end'].line + 1)
    end
  end
  local roots, groups, seen = {}, {}, {}
  local source_cache = {}

  for _, item in ipairs(items) do
    if type(item) == 'table' and type(item.uri) == 'string' and item.uri ~= '' then
      local uri = item.uri
      local range = location_range(item.range)
      local dedupe = item_key(uri, range, kind, item)
      if not seen[dedupe] then
        seen[dedupe] = true
        local path = uri_path(uri)
        local file_key = path ~= '' and path or uri
        local group = groups[file_key]
        if not group then
          local visible_path = relative_path(path ~= '' and path or uri, opts.root)
          group = {
            id = 'file:' .. identity_part(file_key),
            name = path ~= '' and Path.norm(path) or uri,
            display_path = visible_path,
            label = Path.collapse_middle(visible_path, opts.path),
            kind = 'File',
            file_group = true,
            children = {},
          }
          groups[file_key] = group
          roots[#roots + 1] = group
        end

        local read_lines = requested_lines[file_key] or 1
        if configured_max_lines then read_lines = math.min(read_lines, configured_max_lines) end
        local source = source_for(path, source_cache, read_lines)
        local line_index = range.start.line
        local code = source.lines[line_index + 1] or ''
        local encoding = normalize_encoding(item.encoding)
        local byte_col = byte_index(code, encoding, range.start.character)
        local byte_end_col
        if range['end'].line == range.start.line then
          byte_end_col = byte_index(code, encoding, range['end'].character)
        else
          byte_end_col = #code
        end
        if byte_end_col < byte_col then byte_end_col = byte_col end

        local message = type(item.message) == 'string' and item.message or nil
        local name = ('%d: %s'):format(line_index + 1, code)
        if message and message ~= '' then name = name .. '  ' .. message end
        local child_kind = kind
        if kind == 'Diagnostic' or kind == 'Diagnostics' then child_kind = diagnostic_kind(item.severity) or kind end
        group.children[#group.children + 1] = {
          id = child_id(file_key, uri, range, kind, item),
          name = name,
          label = name,
          kind = child_kind,
          uri = uri,
          range = copy(range),
          selection_range = copy(range),
          encoding = encoding,
          code = code,
          lang = source.lang,
          lnum = line_index + 1,
          byte_col = byte_col,
          byte_end_col = byte_end_col,
          message = message,
          severity = item.severity,
          source = item.source,
          children = {},
        }
      end
    end
  end

  return roots
end

return M
