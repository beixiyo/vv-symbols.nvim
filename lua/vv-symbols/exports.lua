-- vv-symbols.exports — 从源代码标注 LSP 符号是否属于模块导出 API
--
-- LSP DocumentSymbol 不提供跨语言一致的 export 元信息，因此这里仅在
-- 当前 buffer 有可用 Tree-sitter parser 时做保守的语法识别。无法解析的
-- 语言或无法和符号落点对应时保持 false，由调用方决定是否提供自定义策略

local M = {}

local declaration_types = {
  class_declaration = true,
  function_declaration = true,
  lexical_declaration = true,
  variable_declaration = true,
}

local function parser_language(buf)
  if type(buf) ~= 'number' or not vim.api.nvim_buf_is_valid(buf) then return nil end
  local filetype = vim.bo[buf].filetype
  if filetype == 'typescriptreact' or filetype == 'tsx' or filetype == 'javascriptreact' then return 'tsx' end
  if filetype == 'typescript' then return 'typescript' end
  if filetype == 'javascript' then return 'javascript' end
  return nil
end

--- 当前 buffer 的语言是否有导出识别（JS/TS/TSX 语法层识别 export 语句）；
--- 其它语言无识别，调用方按「导出信息未知」处理
---@param buf? integer
---@return boolean
function M.detects(buf)
  return parser_language(buf) ~= nil
end

local function text(node, buf)
  local ok, value = pcall(vim.treesitter.get_node_text, node, buf)
  return ok and type(value) == 'string' and value or ''
end

local function first_field(node, field)
  local values = node:field(field)
  return values and values[1]
end

local function child_of_type(node, kind)
  for child in node:iter_children() do
    if child:type() == kind then return child end
  end
end

local function name_node(declaration)
  local named = first_field(declaration, 'name')
  if named then return named end
  for child in declaration:iter_children() do
    if child:type() == 'identifier' or child:type() == 'type_identifier' then return child end
  end
end

local function add_target(targets, node, kind)
  local name = text(node, targets.buf)
  if name ~= '' then
    local line, start_col, end_line, end_col = node:range()
    targets[#targets + 1] = {
      name = name,
      line = line,
      start_col = start_col,
      end_line = end_line,
      end_col = end_col,
      kind = kind,
    }
  end
end

local function add_declaration(targets, declaration)
  local kind = declaration:type()
  if kind == 'lexical_declaration' or kind == 'variable_declaration' then
    for child in declaration:iter_children() do
      if child:type() == 'variable_declarator' then
        local name = name_node(child)
        if name then add_target(targets, name, 'declaration') end
      end
    end
    return
  end
  local name = name_node(declaration)
  if name then add_target(targets, name, kind == 'class_declaration' and 'class' or 'declaration') end
end

local function has_from(export_statement)
  return first_field(export_statement, 'source') ~= nil or child_of_type(export_statement, 'string') ~= nil
end

local function export_specifier_names(specifier, buf)
  local identifiers = {}
  for child in specifier:iter_children() do
    if child:type() == 'identifier' or child:type() == 'type_identifier' then
      identifiers[#identifiers + 1] = { name = text(child, buf), node = child }
    end
  end
  return identifiers[1], identifiers[2]
end

local function top_level_declarations(root, buf)
  local declarations, imports = {}, {}
  for statement in root:iter_children() do
    local kind = statement:type()
    if kind == 'import_statement' then
      for child in statement:iter_children() do
        local imported = child:type() == 'import_clause' and child or nil
        if imported then
          for descendant in imported:iter_children() do
            if descendant:type() == 'identifier' then imports[text(descendant, buf)] = true end
            if descendant:type() == 'named_imports' then
              for specifier in descendant:iter_children() do
                if specifier:type() == 'import_specifier' then
                  local local_name = first_field(specifier, 'alias') or first_field(specifier, 'name')
                  if local_name then imports[text(local_name, buf)] = true end
                end
              end
            end
          end
        end
      end
    elseif declaration_types[kind] then
      local name = name_node(statement)
      if kind == 'lexical_declaration' or kind == 'variable_declaration' then
        for declarator in statement:iter_children() do
          if declarator:type() == 'variable_declarator' then
            local declarator_name = name_node(declarator)
            if declarator_name then declarations[text(declarator_name, buf)] = declarator_name end
          end
        end
      elseif name then
        declarations[text(name, buf)] = name
      end
    end
  end
  return declarations, imports
end

local function matches(node, target, buf, encoding, source_uri)
  if node.name ~= target.name then return false end
  if source_uri and node.uri ~= source_uri then return false end
  local range = node.selection_range or node.selectionRange or node.range
  local start = range and range.start
  if not start or start.line ~= target.line then return false end
  local line = vim.api.nvim_buf_get_lines(buf, target.line, target.line + 1, false)[1] or ''
  local col = target.start_col
  if encoding and encoding ~= 'utf-8' then
    local ok, converted = pcall(vim.str_utfindex, line, encoding, col, false)
    if ok then col = converted end
  end
  return start.character == col
end

local function mark(nodes, targets, buf, encoding, source_uri)
  for _, node in ipairs(nodes or {}) do
    node.exported = false
    for _, target in ipairs(targets) do
      if matches(node, target, buf, encoding, source_uri) then
        node.exported = true
        break
      end
    end
    mark(node.children, targets, buf, encoding, source_uri)
  end
end

---标注符号树中的模块导出 API。识别失败时所有节点保持 `exported=false`
---@param nodes VVSymbolsNode[] 由 model.normalize 生成的符号树
---@param opts? {buf?:integer,encoding?:string} 源 buffer 与 LSP offset encoding
function M.annotate(nodes, opts)
  opts = opts or {}
  local source_uri = ''
  if type(opts.buf) == 'number' and vim.api.nvim_buf_is_valid(opts.buf) then
    local ok, uri = pcall(vim.uri_from_bufnr, opts.buf)
    if ok then source_uri = uri end
  end
  mark(nodes, {}, opts.buf, opts.encoding, source_uri)
  local language = parser_language(opts.buf)
  if not language then return nodes end
  local ok_parser, parser = pcall(vim.treesitter.get_parser, opts.buf, language)
  if not ok_parser or not parser then return nodes end
  local ok_trees, trees = pcall(parser.parse, parser)
  if not ok_trees or not trees or not trees[1] then return nodes end
  local root = trees[1]:root()
  local targets = { buf = opts.buf }
  local declarations, imports = top_level_declarations(root, opts.buf)

  for statement in root:iter_children() do
    if statement:type() == 'export_statement' and not has_from(statement) then
      local declaration
      for child in statement:iter_children() do
        if declaration_types[child:type()] then declaration = child end
      end
      if declaration then
        add_declaration(targets, declaration)
      else
        local clause = child_of_type(statement, 'export_clause')
        if clause then
          for specifier in clause:iter_children() do
            if specifier:type() == 'export_specifier' then
              local local_name, exported_name = export_specifier_names(specifier, opts.buf)
              if local_name and not imports[local_name.name] and declarations[local_name.name] then
                add_target(targets, declarations[local_name.name], 'declaration')
                if exported_name then
                  -- 别名也可能被某些 LSP server 作为 symbol name 返回；保留别名落点
                  add_target(targets, exported_name.node, 'alias')
                end
              end
            end
          end
        elseif child_of_type(statement, 'default') then
          for child in statement:iter_children() do
            if child:type() == 'identifier' and declarations[text(child, opts.buf)] then
              add_target(targets, declarations[text(child, opts.buf)], 'declaration')
            end
          end
        end
      end
    end
  end

  mark(nodes, targets, opts.buf, opts.encoding, source_uri)
  return nodes
end

return M
