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

## Demo

<table align="center">
  <tr>
    <td align="center"><a href="https://github.com/beixiyo/vv-symbols.nvim/releases/download/assets-2026-09-30/symbols.png">Symbol tree<br><img src="https://github.com/beixiyo/vv-symbols.nvim/releases/download/assets-2026-09-30/symbols.png" alt="Symbol tree" width="500"></a></td>
    <td align="center"><a href="https://github.com/beixiyo/vv-symbols.nvim/releases/download/assets-2026-09-30/references-count.png">Reference counts<br><img src="https://github.com/beixiyo/vv-symbols.nvim/releases/download/assets-2026-09-30/references-count.png" alt="Reference counts" width="500"></a></td>
  </tr>
  <tr>
    <td align="center"><a href="https://github.com/beixiyo/vv-symbols.nvim/releases/download/assets-2026-09-30/references.png">References<br><img src="https://github.com/beixiyo/vv-symbols.nvim/releases/download/assets-2026-09-30/references.png" alt="References" width="500"></a></td>
    <td align="center"><a href="https://github.com/beixiyo/vv-symbols.nvim/releases/download/assets-2026-09-30/preview.png">Floating preview<br><img src="https://github.com/beixiyo/vv-symbols.nvim/releases/download/assets-2026-09-30/preview.png" alt="Floating preview" width="500"></a></td>
  </tr>
</table>

## Why replace Trouble

- Trouble gets stuck during continuous resizing and requires switching windows to recover.
- It lacks a complete workflow for interactive filtering by name, path, and symbol type.
- It does not display function reference counts directly in source files.

vv-symbols brings symbols, references, definitions, implementations, diagnostics, quickfix, and loclist into one sidebar, with no dependency on Trouble.

## Features

- Filter the symbol tree by name and type, with a quick toggle for functions only (classes count as callable).
- Browse locations grouped by file, with shortened paths, trimmed code snippets, and Tree-sitter syntax highlighting.
- Preview source as the list cursor moves, then confirm the jump or exit to restore the original position.
- `gp` peeks the cursor symbol's LSP location in a floating window (`require('vv-symbols').peek()`): declarations for type names, implementations otherwise; cycle multiple results with ]p / [p, Enter to jump. The plugin registers `gp` as a buffer-local key on LSP attach (overriding the built-in `gp`); change or disable it with `peek.keys`.
- Display reference counts above symbols or at the end of their definition lines; every exported symbol by default (variables/constants included), or exported callables only with `callable_only = true`.
- Export detection covers `export function/class/const`, re-export clauses and default exports. Exported classes count as
reference targets themselves (invoked via `new`), while their members are class-internal API and never count as module
exports; arrow functions and function expressions assigned to
variables are recognized, including HOC-style identifier-call wrappers such as `memo(() => …)` (method calls like
`list.map(() => …)` are not).
- Keep shortcut hints fixed at the bottom, with arrow navigation, folding, and `g?` help.
- Take over native quickfix / loclist windows by default: native windows opened by `:copen`, `:lopen`, etc. are closed and shown in the sidebar instead, with loclists bound to their owning code window; set `quickfix.replace_native = false` to opt out.
- VS Code-style Ctrl+click go to definition (same implementation as `locations({ method = 'definition' })`: a single result jumps directly, multiple results open the list), with identifiers underlined while hovering with Ctrl held; only intercepted in regular file windows with a definition-capable LSP client, set `mouse = false` to opt out.

## Installation and configuration

Requires Neovim 0.12+, `vv-utils.nvim`, and an LSP server for the language. Source highlighting requires the corresponding Tree-sitter parser; Lua documentation comments also require the `luadoc` parser and query files.

Add a file under LazyVim's `lua/plugins/`, or include this spec in your lazy.nvim plugin list:

```lua
return {
  {
    'beixiyo/vv-symbols.nvim',
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
        scope = 'exported',  -- 'exported' / 'all'; export detection supports JS/TS/TSX.
                            --   Languages without detection treat top-level callables as the module API
        callable_only = false, -- true restricts counts to callables (the top-level fallback only ever covers callables)
        position = 'eol',    -- 'eol' at the end of its definition line / 'above' the symbol
        label = 'refs',      -- Count label text, or fun(count) for singular/plural, shared by lens and panel
        -- filter = function(node) return node.name ~= 'internal' end,
        -- filter runs after scope; use scope = 'all' for custom rules in other languages
      },
      peek = {
        -- Where the size comes from: 'content' fits the content and treats both ratios as caps
        -- (height never drops below half the screen); 'screen' uses the ratios as the actual size.
        -- Both ratios are relative to the whole editor (terminal)
        size = 'content',
        width_ratio = 0.8,   -- Share of editor columns
        height_ratio = 0.75, -- Share of available editor lines
        border = 'rounded',  -- Peek window border
        -- Method used when peek() gets none: 'auto' queries definition on type names
        -- (interface/type/enum... semantic tokens) and implementation otherwise; or pin one, e.g. 'definition'
        method = 'auto',
        -- trigger is registered buffer-local on LSP attach to file buffers (overrides the built-in gp);
        -- confirm / next / prev act inside the float. false disables one key, keys = false disables all
        keys = { trigger = 'gp', confirm = '<CR>', next = ']p', prev = '[p' },
      },
      locations = {
        jump_single_result = true, -- Jump directly to a single definition/reference/etc.; no results stay silent
        -- Whether references in location lists (grr, etc.) and peek include declarations; nil follows
        -- references.include_declaration. Only affects references requests, never lens counts.
        -- true matches VS Code Find All References: in TypeScript it also lists definitions and import lines
        include_declaration = nil,
      },
      -- Ctrl+mouse; mouse = false disables everything
      mouse = {
        -- Normal-mode Ctrl+click goes to definition. true calls locations({ method = 'definition' });
        -- a function(ctx) ... end runs a custom jump (ctx = { buf, win }; the clicked window is current and
        -- the cursor is already at the click position)
        goto_definition = true,
        -- Underline identifiers (VVSymbolsLink) while moving the mouse with Ctrl held; ranges come from
        -- 'iskeyword' only, no LSP request. Turns 'mousemoveevent' on when off and restores it by ownership on disable
        underline = true,
      },
      quickfix = {
        -- Close native quickfix/loclist windows when they open, return to the owning code window and open
        -- the sidebar instead; skipped when the owner is invalid or itself a quickfix window
        replace_native = true,
      },
      references = {
        concurrency = 4,           -- Maximum concurrent automatic reference queries
        max_symbols = 200,         -- Maximum symbols with automatic counts
        include_declaration = false, -- Lens counts exclude declarations; location lists follow unless locations.include_declaration is set
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

### Reference counts on folded lines (nvim-ufo)

Folded lines are rendered by the folding plugin, so end-of-line counts disappear once a fold closes. Query them and
append to the fold text yourself:

```lua
require('vv-symbols').reference_chunks(buf, lnum)
-- ready 结果返回 { {icon, 'VVSymbolsReferenceIcon'}, {count, 'VVSymbolsReferenceCount'}, {' refs', 'VVSymbolsLens'} }
-- 其它状态返回 nil
```

With nvim-ufo, pass a `fold_virt_text_handler` that appends the chunks (ufo re-renders closed folds on its update
cycle, so late-arriving counts refresh automatically).
A working handler lives in my dotfiles:
[`.config/nvim/lua/plugins/specs/ui/ufo.lua`](https://github.com/beixiyo/dotfiles/blob/main/.config/nvim/lua/plugins/specs/ui/ufo.lua).

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
| `F` | Toggle functions only/all types in the symbol tree (classes count as callable) |
| `R` | Show references to the selected symbol |
| `Backspace` | Return to the symbol tree when references were opened from it |
| `c` | Clear filters |
| `r` | Refresh the current list |
| `g?` | Show shortcuts available in the current view |

Lists opened directly with `grr` have no parent view to return to. Footer hints and help show only keys available in the current view and follow custom mappings.

## Filtering

The symbol tree matches symbol names. Location lists match file paths, result code lines, and diagnostic messages, without searching entire files. A path match keeps all results in that file; otherwise, only matching rows remain. Type or severity filters still apply.

In the input box, `Shift-Tab` switches matching modes, `Ctrl-N/P` moves through results, `Enter` accepts the filter, and `Esc` restores the previous query. Invalid regex patterns keep the last valid results. Clearing the filter restores the previous fold state.

## Highlight groups

All groups are registered with `default = true`, so colorscheme or user definitions take precedence; they are reapplied after the colorscheme changes.

| Group | Default |
|---|---|
| `VVSymbolsPreview` | Landing spot in list previews and peek: links to `CurSearch`, so the color follows your colorscheme; override with `nvim_set_hl` to style it separately |
| `VVSymbolsName` / `VVSymbolsKind` | Links to `Normal` / `Type` |
| `VVSymbolsLens` | Links to `Comment` |
| `VVSymbolsReferenceIcon` / `VVSymbolsReferenceCount` | Links to `Special` / `VVSymbolsReferenceIcon` |
| `VVSymbolsZeroReferences` | Links to `DiagnosticError` |
| `VVSymbolsLink` | Jumpable identifier while hovering with Ctrl held: links to `Underlined` |
| `VVSymbolsReferenceMatch` | Empty (reference ranges are not marked inside lists) |

## Common commands

| Command | Action |
|---|---|
| `:VVSymbolsToggle` | Toggle the current file's symbol tree |
| `:VVSymbolsReferences` | Show references at the cursor |
| `:VVSymbolsPeek` | Peek the cursor symbol's LSP location in a floating window (method per `peek.method`) |
| `:VVSymbolsDiagnostics` | Show workspace diagnostics |
| `:VVSymbolsQuickfix` | Show quickfix |
| `:VVSymbolsLoclist` | Show the current window's loclist |
| `:VVSymbolsRefresh` | Refresh the list and reference counts |
| `:VVSymbolsLensEnable` / `:VVSymbolsLensDisable` | Enable/disable reference hints in source files |

For more APIs and configuration types, see [config.lua](lua/vv-symbols/config.lua) and [init.lua](lua/vv-symbols/init.lua).

## Development tests

```sh
./tests/run.sh [literal-filter]
```

Requires Unix-like OS, Neovim 0.12+, Git, POSIX shell and existing `vv-utils.nvim` source. `VV_UTILS` and `NVIM_BIN` can override discovery and the executable. The full suite needs existing `vv-splits.nvim` source (`VV_TEST_SPLITS`, test-only), plus `lua`, `luadoc`, `typescript` and `tsx` parsers. Set `VV_TEST_PARSERS` or `VV_TEST_SITE` to their runtime root. Highlight queries must include `lua`, `luadoc`, `typescript`, `tsx` and inherited `ecma` / `jsx`, plus Lua's LuaDoc injection query; they are taken from site or existing nvim-treesitter source (`VV_TEST_QUERIES` override). No language server is required by the fixtures.

The shared runner uses isolated children without personal configuration. Dependency discovery, CI checkouts and isolation are documented in the [shared test guide](https://github.com/beixiyo/vv-utils.nvim/blob/main/dev/test/README.md). Headless tests do not replace TUI verification; CI needs an outer job timeout.
