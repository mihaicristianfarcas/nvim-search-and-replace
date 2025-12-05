# nvim-search-and-replace

A Neovim plugin for performing project-wide search and replace operations with a visual interface and live preview.

## Preview

![Preview](assets/preview.gif)
## Overview

`nvim-search-and-replace` provides a custom split-pane UI for finding and replacing text across your entire project. It integrates with `ripgrep` for fast searching and offers a safe, visual workflow with live previews before making changes.

### Key Features

- **Async Live Search** - Fast streaming search results with async ripgrep integration
- **Visual Preview** - Side-by-side comparison showing before and after changes
- **Jump To Match** - Open the previewed file directly at the matched location
- **Regex Support** - Toggle between literal string matching and regex patterns with `Ctrl-t`
- **Selective Replacement** - Mark specific items or replace all matches at once
- **Pre-filled Search** - Open with visual selection, search pattern (`*`), or word under cursor
- **Safe Replacements** - Validates exact text matches before writing to prevent unintended modifications
- **Undo/Redo** - Full undo/redo stack for all replacement operations
- **Syntax Highlighting** - Color-coded filenames, line numbers, and matched text
- **Search Cancellation** - Stop long-running searches with `Ctrl-x`
- **Built-in Help** - Press `?` or `F1` for keybinding reference

## Requirements

- Neovim 0.8 or later
- [ripgrep](https://github.com/BurntSushi/ripgrep) (`rg`) installed and available in PATH

## Installation

### Using [lazy.nvim](https://github.com/folke/lazy.nvim)

```lua
{
  "mihaicristianfarcas/nvim-search-and-replace",
  cmd = "SearchAndReplaceOpen",
  keys = {
    { "<leader>sar", "<cmd>SearchAndReplaceOpen<cr>", desc = "[S]earch [A]nd [R]eplace" },
    { "<leader>saw", "<cmd>SearchAndReplaceVisual<cr>", desc = "[S]earch [A]nd replace [W]ord" },
  },
  opts = {
    -- Optional configuration
    rg_binary = "rg",
    literal = true,
    smart_case = true,
    max_results = 10000,
  },
}
```

### Using [packer.nvim](https://github.com/wbthomason/packer.nvim)

```lua
use {
  "mihaicristianfarcas/nvim-search-and-replace",
  config = function()
    require("nvim-search-and-replace").setup({
      rg_binary = "rg",
      literal = true,
      smart_case = true,
      max_results = 10000,
    })
  end
}
```

## Usage

### Opening the Interface

Execute the following command to open the search and replace interface:

```vim
:SearchAndReplaceOpen
```

Or open with text from visual selection or word under cursor:

```vim
:SearchAndReplaceVisual
```

You can also open with a specific search term:

```vim
:SearchAndReplaceOpen search_term
```

### Quick Workflows

**From visual selection or `*` search:**
1. Select text in visual mode (or press `*` to search word under cursor)
2. Run `:SearchAndReplaceVisual` (or map it to a key like `<leader>saw`)
3. The interface opens with your selection pre-filled
4. Enter replacement text and press `Ctrl-a` to replace all

**Regex search:**
1. Open the interface with `:SearchAndReplaceOpen`
2. Press `Ctrl-t` to toggle regex mode
3. Enter regex pattern (e.g., `\d+` to match numbers)
4. Enter replacement text (supports capture groups like `\1`, `\2`)
5. Review matches and replace

### Interface Layout

The UI consists of four main panes:

```
┌─ Search ────────────────┐  ┌─ Preview ──────────────┐
│ search_term             │  │ ╔═══ src/file.lua ═══  │
├─ Replace ───────────────┤  │                        │
│ replacement_text        │  │  BEFORE: search_term   │
├─ Results ───────────────┤  │  AFTER:  replacement   │
│ ▶ src/file.lua:10       │  │                        │
│   lib/util.lua:25       │  └────────────────────────┘
└─────────────────────────┘
```

### Workflow

1. Enter search term in the top field (results update live as you type)
2. Enter replacement text in the second field (preview updates automatically)
3. Navigate through results using `j`/`k` keys
4. Review changes in the preview pane
5. **Option A**: Press `Tab` to mark specific items, then `Enter` to replace marked items
6. **Option B**: Press `Ctrl-a` to replace all matches at once
7. Use `u` or `Ctrl-z` to undo, `Ctrl-r` to redo

### Keybindings

#### Help
| Key | Mode | Action |
|-----|------|--------|
| `?` / `F1` | Normal/Insert | Toggle help window |

#### Navigation
| Key | Mode | Action |
|-----|------|--------|
| `Ctrl-j` | Normal/Insert | Cycle through fields (search → replace → results) |
| `Tab` | Insert | Move to next field (search → replace → results) |
| `Shift-Tab` | Insert | Move to previous field |
| `j` / `k` / `↑` / `↓` | Normal | Navigate results list |
| `i` / `a` | Normal (in results) | Jump to search field (insert mode) |
| `I` | Normal (in results) | Jump to replace field (insert mode) |

#### Selection
| Key | Mode | Action |
|-----|------|--------|
| `Tab` | Normal (in results) | Mark/select current item |
| `Shift-Tab` | Normal (in results) | Unmark/unselect current item |

#### Actions
| Key | Mode | Action |
|-----|------|--------|
| `Enter` | Normal (in results) | Replace current item (or all marked items if any) |
| `o` | Normal (in results) | Open the previewed file at the matched location |
| `Ctrl-a` | Normal/Insert | Replace ALL matches |
| `Ctrl-t` | Normal/Insert | Toggle between literal and regex mode |
| `Ctrl-x` | Normal/Insert | Stop/abort current search |
| `u` / `Ctrl-z` | Normal/Insert | Undo last replacement |
| `Ctrl-r` / `Ctrl-Shift-z` | Normal/Insert | Redo last replacement |

#### Window Management
| Key | Mode | Action |
|-----|------|--------|
| `Esc` / `q` | Normal | Close interface |
| `Ctrl-c` | Normal/Insert | Close interface |

## Configuration

The plugin can be configured during setup:

```lua
require("nvim_search_and_replace").setup({
  -- Path to ripgrep binary (default: "rg")
  rg_binary = "rg",
  
  -- Use literal string matching instead of regex (default: true)
  -- Recommended for predictable replacements
  literal = true,
  
  -- Case-insensitive search unless uppercase letters are used (default: true)
  smart_case = true,
  
  -- Maximum number of search results to display (default: 10000)
  max_results = 10000,
})
```

### Configuration Options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `rg_binary` | string | `"rg"` | Path to the ripgrep executable |
| `literal` | boolean | `true` | Use exact string matching (recommended) |
| `smart_case` | boolean | `true` | Case-insensitive search unless uppercase is present |
| `max_results` | number | `10000` | Maximum number of search results to display |

## Commands

| Command | Description |
|---------|-------------|
| `:SearchAndReplaceOpen [term]` | Open the search and replace interface, optionally with a search term |
| `:SearchAndReplaceVisual` | Open with visual selection, search pattern (`/` register), or word under cursor |
| `:SearchAndReplaceUndo` | Undo the most recent replacement operation |
| `:SearchAndReplaceRedo` | Redo the most recent undone replacement operation |

## How It Works

1. **Async Search**: Uses `ripgrep` with async streaming for fast, non-blocking search across the project
2. **Token-based Cancellation**: Unique tokens prevent stale search results from updating UI after new searches start
3. **Live Preview**: Real-time preview updates as you type with debounced search (300ms)
4. **Validation**: Before writing, validates that the text at each location still matches the search term
5. **Replacement**: Writes changes to files only when validation passes (supports regex capture groups)
6. **History Stack**: Full undo/redo stack stores previous file content for all operations

### Safety Features

- **Exact Match Validation**: Only replaces text that exactly matches at the specified location
- **Skip Mismatches**: If text has changed since the replace, the replacement is skipped
- **Detailed Reporting**: Shows which replacements succeeded and which were skipped
- **Undo Support**: Maintains history to revert changes if needed

## Limitations

- Only single-line matches are currently supported
- File operations are synchronous (search is async, file writes are not)
- Follows ripgrep's default ignore rules (respects `.gitignore`)
- Search results limited by `max_results` config (default: 10,000)

## Troubleshooting

### Matches are skipped during replacement

This is expected behavior. The plugin validates that the text at each match location exactly matches your replace term before replacing. Mismatches can occur due to:
- Text being modified since the initial replace
- Partial matches at the specified column position
- Case sensitivity differences

### Preview not updating

Ensure you're in the correct input field and typing. The preview updates automatically after a 300ms debounce period.

### Search is taking too long

Press `Ctrl-x` to stop the current search. Consider using more specific search terms or enabling literal mode for faster searches.

## Contributing

Contributions are welcome. Please ensure:
- Code follows existing style
- Changes are tested with Neovim 0.8+
- Commit messages are descriptive

## License

MIT
