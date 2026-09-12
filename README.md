<div align="center">
  <h1>vv-symbols.nvim</h1>
  <p>English | <a href="./README.zh-CN.md">中文</a></p>
  <p>Want my Neovim configuration? Check out <a href="https://github.com/beixiyo/dotfiles">dotfiles</a></p>
  <em>LSP symbol trees, reference counts, and location lists</em>
  <p>
    <img src="https://img.shields.io/badge/Neovim-0.12+-57A143?style=flat-square&logo=neovim&logoColor=white" alt="Neovim 0.12+" />
    <img src="https://img.shields.io/badge/Lua-2C2D72?style=flat-square&logo=lua&logoColor=white" alt="Lua" />
  </p>
</div>

## Why replace Trouble

- Trouble gets stuck during continuous resizing and requires switching windows to recover.
- It lacks a complete workflow for interactive filtering by name, path, and symbol type.
- It does not display function reference counts directly in source files.

vv-symbols brings symbols, references, definitions, implementations, diagnostics, quickfix, and loclist into one sidebar, with no dependency on Trouble.

## Features

- Filter the symbol tree by name and type, with a quick toggle for functions only.
- Browse locations grouped by file, with shortened paths, trimmed code snippets, and Tree-sitter syntax highlighting.
- Preview source as the list cursor moves, then confirm the jump or exit to restore the original position.
- Display reference counts above symbols or at the end of their definition lines; exported functions only by default.
- Keep shortcut hints fixed at the bottom, with arrow navigation, folding, and `g?` help.

## Installation and configuration

Requires Neovim 0.12+, `vv-utils.nvim`, and an LSP server for the language. Source highlighting requires the corresponding Tree-sitter parser; Lua documentation comments also require the `luadoc` parser and query files.

Add a file under LazyVim's `lua/plugins/`, or include this spec in your lazy.nvim plugin list. This example currently uses a local plugin directory:

```lua
return {
  {
    dir = vim.fn.expand('~/.config/nvim/vendors/vv-symbols.nvim'),
    name = 'vv-symbols.nvim',
    dependencies = {
      'beixiyo/vv-utils.nvim',
      'beixiyo/vv-icons.nvim', -- Optional, for consistent icons
    },
    opts = {
      panel = {
        width = 42,           -- Initial width; manual resizing preserves the new width
        position = 'left',    -- 'left' / 'right'
        preview = true,       -- Preview source as the cursor moves
        state = false,        -- Pass a vv-utils.state handle to persist the width
      },
      filter = {
        mode = 'subseq',      -- Subsequence; also 'fixed' substring or 'regex'
        kinds = false,       -- All types; use { 'Function' } for functions only
        debounce_ms = 150,    -- Filter input debounce
      },
      lens = {
        enabled = true,      -- Show reference counts; disabling stops automatic queries
        scope = 'exported',  -- 'exported' / 'all'; export detection supports JS/TS/TSX
        position = 'above',  -- 'above' the symbol / 'eol' at the end of its definition line
        -- filter = function(node) return node.name ~= 'internal' end,
        -- filter runs after scope; use scope = 'all' for custom rules in other languages
      },
      locations = {
        jump_single_result = true, -- Jump directly to a single definition/reference/etc.; no results stay silent
      },
      references = {
        concurrency = 4,           -- Maximum concurrent automatic reference queries
        max_symbols = 200,         -- Maximum symbols with automatic counts
        include_declaration = false, -- Exclude declaration locations from reference counts
      },
      timing = {
        debounce_ms = 250,   -- Debounce analysis after source edits
        timeout_ms = 3000,   -- LSP request timeout
      },
      max_lines = 5000,      -- Skip automatic analysis for files exceeding this limit
      -- keymaps = { ['/'] = false, s = 'filter' }, -- Override panel mappings; false disables a key
    },
    keys = {
      { 'go', '<cmd>VVSymbolsToggle<cr>', desc = 'Symbol tree' },
      { 'grr', '<cmd>VVSymbolsReferences<cr>', desc = 'References' },
      { 'gd', function() require('vv-symbols').locations({ method = 'definition' }) end, desc = 'Definition' },
      { 'gri', function() require('vv-symbols').locations({ method = 'implementation' }) end, desc = 'Implementation' },
      { 'grt', function() require('vv-symbols').locations({ method = 'type_definition' }) end, desc = 'Type definition' },
      { '<leader>xx', '<cmd>VVSymbolsDiagnostics<cr>', desc = 'Workspace diagnostics' },
    },
  },
}
```

Icons and reference counts use the theme's `Special` color; zero references use `DiagnosticError`. `0 references` means the LSP found no references, not that the code is safe to delete. `…` indicates a pending query, and `?` indicates failure or timeout.

## Panel controls

| Key | Action |
|---|---|
| `j/k`, `↑/↓`, `Ctrl-N/P` | Move and preview, skipping expanded file headers |
| `h/←` | Collapse the current node or its file group |
| `l/→` | Expand and select the first result; enter source when on a result |
| `Enter` | Confirm the jump and keep the sidebar open |
| `gf` | Confirm the jump and close the sidebar |
| `q/Esc` | Exit; restore the original position if the preview was not confirmed |
| `Tab` | Toggle folding |
| `zR/zM` | Expand/collapse all |
| `/` | Enter a filter |
| `t` | Filter by symbol type, or by severity in diagnostics |
| `F` | Toggle functions only/all types in the symbol tree |
| `R` | Show references to the selected symbol |
| `Backspace` | Return to the symbol tree when references were opened from it |
| `c` | Clear filters |
| `r` | Refresh the current list |
| `g?` | Show shortcuts available in the current view |

Lists opened directly with `grr` have no parent view to return to. Footer hints and help show only keys available in the current view and follow custom mappings.

## Filtering

The symbol tree matches symbol names. Location lists match file paths, result code lines, and diagnostic messages, without searching entire files. A path match keeps all results in that file; otherwise, only matching rows remain. Type or severity filters still apply.

In the input box, `Shift-Tab` switches matching modes, `Ctrl-N/P` moves through results, `Enter` accepts the filter, and `Esc` restores the previous query. Invalid regex patterns keep the last valid results. Clearing the filter restores the previous fold state.

## Common commands

| Command | Action |
|---|---|
| `:VVSymbolsToggle` | Toggle the current file's symbol tree |
| `:VVSymbolsReferences` | Show references at the cursor |
| `:VVSymbolsDiagnostics` | Show workspace diagnostics |
| `:VVSymbolsQuickfix` | Show quickfix |
| `:VVSymbolsLoclist` | Show the current window's loclist |
| `:VVSymbolsRefresh` | Refresh the list and reference counts |
| `:VVSymbolsLensEnable` / `:VVSymbolsLensDisable` | Enable/disable reference hints in source files |

For more APIs and configuration types, see [config.lua](lua/vv-symbols/config.lua) and [init.lua](lua/vv-symbols/init.lua).
