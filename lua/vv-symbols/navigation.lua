-- Location-list navigation policy over the shared tree's visible rows.
local TreeModel = require('vv-utils.tree_panel.model')
local M = {}

--- Expanded file headers are labels, while collapsed groups remain reachable.
function M.lines(tree)
  local lines = {}
  for _, line in ipairs(tree.row_lines) do
    local node = tree.rows[line].node
    local folded = tree.folded[node.id]
    if folded == nil then folded = node.expanded == false end
    if not node.context_only and (not node.file_group or folded) then lines[#lines + 1] = line end
  end
  return lines
end

--- Move by actual results, preserving native counts and shared wrap semantics.
function M.move(tree, direction, count)
  if not tree:is_open() then return end
  local current = vim.api.nvim_win_get_cursor(tree.win)[1]
  local target = TreeModel.move_target(M.lines(tree), current, direction, count or vim.v.count1)
  if target then vim.api.nvim_win_set_cursor(tree.win, { target, 0 }) end
end

--- Expand a file into its first result; leaves retain the shared open action.
function M.open(tree)
  if not tree:is_open() then return end
  local row = tree.rows[vim.api.nvim_win_get_cursor(tree.win)[1]]
  tree:execute('open_node')
  if row and row.node.file_group then
    local first = row.node.children and row.node.children[1]
    local line = first and tree.node_lines[first.id]
    if line then vim.api.nvim_win_set_cursor(tree.win, { line, 0 }) end
  end
end

--- Initial list focus should land on a result rather than a source/header row.
function M.focus_result(tree)
  if not tree:is_open() then return end
  local line = vim.api.nvim_win_get_cursor(tree.win)[1]
  local choices = M.lines(tree)
  if not vim.tbl_contains(choices, line) then M.move(tree, 1, 1) end
end

return M
