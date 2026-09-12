-- vv-symbols.model — 将 LSP 符号归一化为可过滤的文档树
--
-- 本模块只处理符号数据：保留 LSP 原始 range/encoding，补齐稳定身份和
-- 可调用标记，并在过滤时复制树结构。面板、跳转和渲染策略由调用方负责

local Match = require('vv-utils.match')
local Exports = require('vv-symbols.exports')

local M = {}

local symbol_kinds = vim.lsp.protocol.SymbolKind

local function copy(value) return vim.deepcopy(value) end

local function position_value(value)
  if type(value) ~= 'table' then return { line = 0, character = 0 } end
  return {
    line = tonumber(value.line) or 0,
    character = tonumber(value.character) or 0,
  }
end

local function range_value(value)
  if type(value) ~= 'table' then return {
    start = position_value(),
    ['end'] = position_value(),
  } end
  return {
    start = copy(value.start or {}),
    ['end'] = copy(value['end'] or {}),
  }
end

local function kind_values(raw_kind)
  if type(raw_kind) == 'number' then return symbol_kinds[raw_kind] or tostring(raw_kind), raw_kind end

  if type(raw_kind) == 'string' then return raw_kind, symbol_kinds[raw_kind] or 0 end

  return 'Unknown', 0
end

local function make_id(uri, range, name)
  local start = position_value(range.start)
  local finish = position_value(range['end'])
  local uri_value = tostring(uri or '')
  local name_value = tostring(name or '')

  -- 长度前缀避免 URI、名称或位置中出现分隔符时产生碰撞。这里不使用
  -- hash，使 id 在没有额外依赖的 headless 测试和编辑器会话中都可复现
  return table.concat({
    #uri_value,
    uri_value,
    start.line,
    start.character,
    finish.line,
    finish.character,
    #name_value,
    name_value,
  }, ':')
end

local function buffer_uri(buf)
  if type(buf) ~= 'number' or not vim.api.nvim_buf_is_valid(buf) then return '' end
  local ok, uri = pcall(vim.uri_from_bufnr, buf)
  return ok and uri or ''
end

local function buffer_for_uri(uri, fallback)
  if type(uri) ~= 'string' or uri == '' then return fallback end
  local ok, buf = pcall(vim.uri_to_bufnr, uri)
  return ok and buf or fallback
end

local function parser_language(buf)
  if type(buf) ~= 'number' or not vim.api.nvim_buf_is_valid(buf) then return nil end

  local filetype = vim.bo[buf].filetype
  if filetype == '' and vim.filetype and vim.filetype.match then
    local ok, detected = pcall(vim.filetype.match, { buf = buf })
    if ok then filetype = detected or '' end
  end

  if filetype == 'typescriptreact' or filetype == 'tsx' then return 'tsx' end
  if filetype == 'typescript' then return 'typescript' end
  return nil
end

local function first_field(node, field)
  local values = node:field(field)
  return values and values[1]
end

local function contains_child(parent, target)
  for child in parent:iter_children() do
    if child == target then return true end
  end
  return false
end

local transparent_wrappers = {
  as_expression = true,
  non_null_expression = true,
  parenthesized_expression = true,
  satisfies_expression = true,
  type_assertion = true,
}

local callable_owners = {
  pair = 'key',
  property_definition = 'name',
  public_field_definition = 'name',
  variable_declarator = 'name',
}

local function callable_owner(arrow)
  local child = arrow
  local parent = arrow:parent()
  while parent and transparent_wrappers[parent:type()] and contains_child(parent, child) do
    child = parent
    parent = parent:parent()
  end

  if not parent then return end
  local name_field = callable_owners[parent:type()]
  if not name_field then return end
  local value = first_field(parent, 'value')
  if value ~= child then return end
  return first_field(parent, name_field)
end

local function arrow_callable_candidates(buf, encoding)
  local language = parser_language(buf)
  if not language then return {} end

  local ok_parser, parser = pcall(vim.treesitter.get_parser, buf, language)
  if not ok_parser or not parser then return {} end

  local ok_tree, trees = pcall(parser.parse, parser)
  if not ok_tree or not trees or not trees[1] then return {} end

  local ok_query, query = pcall(vim.treesitter.query.parse, language, '(arrow_function) @arrow')
  if not ok_query or not query then return {} end

  local candidates = {}
  local root = trees[1]:root()
  for _, arrow in query:iter_captures(root, buf, 0, -1) do
    local name_node = callable_owner(arrow)
    if name_node then
      local start_line, start_col, end_line, end_col = name_node:range()
      local name = vim.treesitter.get_node_text(name_node, buf)
      if type(name) == 'string' and name ~= '' then
        candidates[#candidates + 1] = {
          name = name,
          line = start_line,
          start_col = start_col,
          end_line = end_line,
          end_col = end_col,
        }
      end
    end
  end

  return candidates
end

local function lsp_character_to_byte(buf, position, encoding)
  if encoding == 'utf-8' then return position.character end
  local line = vim.api.nvim_buf_get_lines(buf, position.line, position.line + 1, false)[1]
  if not line then return end
  local ok, byte = pcall(vim.str_byteindex, line, encoding or 'utf-16', position.character, false)
  if not ok then return end
  return byte
end

local function callable_from_arrow(candidates, name, selection_range, buf, encoding)
  if #candidates == 0 then return false end

  local start = selection_range and selection_range.start
  local finish = selection_range and selection_range['end']
  if not start or not finish then return false end
  local start_col = lsp_character_to_byte(buf, start, encoding)
  local end_col = lsp_character_to_byte(buf, finish, encoding)
  if start_col == nil or end_col == nil then return false end

  for _, candidate in ipairs(candidates) do
    if
      candidate.name == name
      and candidate.line == start.line
      and candidate.end_line == finish.line
      and candidate.start_col == start_col
      and candidate.end_col == end_col
    then
      return true
    end
  end
  return false
end

local function is_builtin_callable(kind) return kind == 'Function' or kind == 'Method' or kind == 'Constructor' end

local function normalize_symbol(symbol, opts, source_uri, arrow_candidates, symbol_information)
  local location = symbol_information and symbol.location or nil
  local raw_range = location and location.range or symbol.range
  local range = range_value(raw_range)
  local selection_range = range_value(symbol.selectionRange or symbol.selection_range or raw_range)
  local uri = (location and location.uri) or source_uri or ''
  local name = type(symbol.name) == 'string' and symbol.name or ''
  local kind, lsp_kind = kind_values(symbol.kind)
  local is_callable = is_builtin_callable(kind)
  local buf = symbol_information and buffer_for_uri(uri, opts.buf) or opts.buf

  if not is_callable and (kind == 'Variable' or kind == 'Constant' or kind == 'Property') then
    is_callable = callable_from_arrow(arrow_candidates, name, selection_range, opts.buf, opts.encoding)
  end

  local node = {
    id = make_id(uri, range, name),
    name = name,
    label = name,
    kind = kind,
    lsp_kind = lsp_kind,
    uri = uri,
    range = range,
    selection_range = selection_range,
    client_id = opts.client_id,
    encoding = opts.encoding,
    buf = buf,
    children = {},
    is_callable = is_callable == true,
    exported = false,
  }

  if not symbol_information then
    for _, child in ipairs(symbol.children or {}) do
      node.children[#node.children + 1] = normalize_symbol(child, opts, source_uri, arrow_candidates, false)
    end
  end

  return node
end

--- 将 LSP DocumentSymbol 或 SymbolInformation 转为统一的符号树
---@param opts VVSymbolsNormalizeOpts
---@return VVSymbolsNode[] roots 按 LSP 文档顺序排列的根节点
function M.normalize(opts)
  opts = opts or {}
  local symbols = type(opts.symbols) == 'table' and opts.symbols or {}
  local source_uri = opts.uri or buffer_uri(opts.buf)
  local arrow_candidates = arrow_callable_candidates(opts.buf, opts.encoding)
  local roots = {}

  for _, symbol in ipairs(symbols) do
    if type(symbol) == 'table' then
      local symbol_information = type(symbol.location) == 'table'
      roots[#roots + 1] = normalize_symbol(symbol, opts, source_uri, arrow_candidates, symbol_information)
    end
  end

  Exports.annotate(roots, { buf = opts.buf, encoding = opts.encoding })
  return roots
end

local function count_nodes(nodes)
  local count = 0
  for _, node in ipairs(nodes or {}) do
    count = count + 1 + count_nodes(node.children)
  end
  return count
end

local function copy_node(node)
  local copied = {}
  for key, value in pairs(node) do
    if key ~= 'children' and key ~= 'context_only' then
      if key == 'range' or key == 'selection_range' then
        copied[key] = copy(value)
      else
        copied[key] = value
      end
    end
  end
  return copied
end

--- 按名称和符号类型过滤树，并为命中的后代保留祖先上下文
---@param opts VVSymbolsFilterOpts
---@return VVSymbolsFilterResult
function M.filter(opts)
  opts = opts or {}
  local input = type(opts.nodes) == 'table' and opts.nodes or {}
  local total = count_nodes(input)
  local query = type(opts.query) == 'string' and opts.query or ''
  local predicate, valid = Match.compile(query, { mode = opts.mode or 'subseq' })

  if not valid then return { nodes = {}, count = 0, total = total, valid = false } end

  local kind_set = {}
  local has_kind_filter = false
  local kinds = type(opts.kinds) == 'table' and opts.kinds or {}
  for _, kind in ipairs(kinds) do
    if type(kind) == 'string' then
      has_kind_filter = true
      kind_set[kind] = true
      kind_set[kind:lower()] = true
    end
  end

  local count = 0
  local function kind_matches(node)
    if not has_kind_filter then return true end
    if kind_set[node.kind] or kind_set[(node.kind or ''):lower()] then return true end
    if kind_set.Function == true or kind_set['function'] == true then return node.is_callable == true end
    return false
  end

  local function filter_nodes(nodes, matched_file)
    local result = {}
    for _, node in ipairs(nodes or {}) do
      local name_matches = predicate(node.name or '')
      local matched = (matched_file or name_matches) and kind_matches(node)
      if matched then count = count + 1 end

      -- File paths select their results; symbol ancestors do not broaden matching.
      -- Kind/severity restrictions still apply independently to every child.
      local children = filter_nodes(node.children, matched_file or node.file_group and name_matches)
      if matched or #children > 0 then
        local filtered = copy_node(node)
        filtered.children = children
        if matched then
          filtered.context_only = nil
        else
          filtered.context_only = true
        end
        result[#result + 1] = filtered
      end
    end
    return result
  end

  return {
    nodes = filter_nodes(input),
    count = count,
    total = total,
    valid = true,
  }
end

--- 按文档顺序展开树，返回节点引用组成的扁平数组
---@param nodes VVSymbolsNode[]
---@return VVSymbolsNode[]
function M.flatten(nodes)
  local result = {}
  local function visit(items)
    for _, node in ipairs(items or {}) do
      result[#result + 1] = node
      visit(node.children)
    end
  end
  visit(nodes)
  return result
end

return M

---@class VVSymbolsNormalizeOpts
---@field symbols? table[] LSP DocumentSymbol[] 或 SymbolInformation[]
---@field buf? integer 请求对应的 buffer
---@field client_id? integer LSP client id
---@field encoding? string LSP offset encoding，例如 `utf-16`
---@field uri? string 测试或 workspace caller 提供的源 URI

---@class VVSymbolsNode
---@field id string 基于 URI、range 和 name 的稳定身份
---@field name string
---@field label string
---@field kind string
---@field lsp_kind integer
---@field uri string
---@field range table LSP 原始编码的 range
---@field selection_range table LSP 原始编码的 selection range
---@field client_id? integer
---@field encoding? string
---@field buf? integer
---@field children VVSymbolsNode[]
---@field is_callable boolean
---@field exported boolean 是否由源代码确认属于模块导出 API
---@field context_only? boolean

---@class VVSymbolsFilterOpts
---@field nodes VVSymbolsNode[]
---@field query? string @default ''
---@field mode? 'subseq'|'fixed'|'regex' @default 'subseq'
---@field kinds? string[]

---@class VVSymbolsFilterResult
---@field nodes VVSymbolsNode[] 保留上下文后的新树
---@field count integer 命中的节点数，不含 context_only 节点
---@field total integer 输入树中的节点总数
---@field valid boolean regex 是否有效
