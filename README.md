# nvim-search-and-replace

A Neovim plugin for performing project-wide search and replace operations with a visual interface and live preview.

## Preview

![Preview](assets/preview.gif)
## Overview

`nvim-search-and-replace` provides a custom split-pane UI for finding and replacing text across your entire project. It integrates with `ripgrep` for fast searching and offers a safe, visual workflow with live previews before making changes.

### Key Features

- **Live Search Results** - Results update automatically as you type
- **Visual Preview** - Side-by-side comparison showing before and after changes
- **Safe Replacements** - Validates exact text matches before writing to prevent unintended modifications
- **Syntax Highlighting** - Color-coded filenames, line numbers, and matched text
- **Undo Support** - Revert the last batch of replacements with a single keypress
- **Text Wrapping** - Full text visibility in results and preview panes
- **Relative Paths** - Clean display of file paths relative to working directory

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
  },
  opts = {
    -- Optional configuration
    rg_binary = "rg",
    literal = true,
    smart_case = true,
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

1. Enter search term in the top field
2. Enter replacement text in the second field
3. Navigate through results using `j`/`k` keys
4. Review changes in the preview pane
5. Press `Enter` to replace the selected item or `Ctrl-a` to replace all matches
6. Use `u` to undo if needed

### Keybindings

#### Navigation
| Key | Mode | Action |
|-----|------|--------|
| `Tab` | Normal | Select file(s) |
| `Shift-Tab` | Normal | Unselect file(s) |
| `Ctrl-j` | Normal/Insert | Cycle through fields (search → replace → results) |
| `j` / `k` | Normal | Navigate results list |
| `↑` / `↓` | Normal | Navigate results list |

#### Actions
| Key | Mode | Action |
|-----|------|--------|
| `Enter` | Normal | Replace selected match |
| `Ctrl-a` | Normal | Replace all matches |
| `u` | Normal | Undo last replacement operation |
| `Ctrl-z` | Normal/Insert | Undo last replacement operation |
| `i` / `a` | Normal | Jump to search field (insert mode) |
| `I` | Normal | Jump to replace field (insert mode) |

#### Window Management
| Key | Mode | Action |
|-----|------|--------|
| `Esc` | Normal | Close interface |
| `q` | Normal | Close interface |
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
})
```

### Configuration Options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `rg_binary` | string | `"rg"` | Path to the ripgrep executable |
| `literal` | boolean | `true` | Use exact string matching (recommended) |
| `smart_case` | boolean | `true` | Case-insensitive search unless uppercase is present |

## Commands

| Command | Description |
|---------|-------------|
| `:SearchAndReplaceOpen` | Open the search and replace interface |
| `:SearchAndReplaceUndo` | Undo the most recent replacement operation |

## How It Works

1. **Search**: Uses `ripgrep` to quickly find all matches across the project
2. **Preview**: Displays matched lines with context and shows how replacements will appear
3. **Validation**: Before writing, validates that the text at each location still matches the replace term
4. **Replacement**: Writes changes to files only when validation passes
5. **History**: Stores previous file content for undo functionality

### Safety Features

- **Exact Match Validation**: Only replaces text that exactly matches at the specified location
- **Skip Mismatches**: If text has changed since the replace, the replacement is skipped
- **Detailed Reporting**: Shows which replacements succeeded and which were skipped
- **Undo Support**: Maintains history to revert changes if needed

## Limitations

- Only single-line matches are currently supported
- Uses synchronous file operations (no async I/O)
- Follows ripgrep's default ignore rules (respects `.gitignore`)

## Troubleshooting

### Matches are skipped during replacement

This is expected behavior. The plugin validates that the text at each match location exactly matches your replace term before replacing. Mismatches can occur due to:
- Text being modified since the initial replace
- Partial matches at the specified column position
- Case sensitivity differences

### Preview not updating

Ensure you're in the correct input field and typing. The preview updates automatically after a 300ms debounce period.

## Contributing

Contributions are welcome. Please ensure:
- Code follows existing style conventions
- Changes are tested with Neovim 0.8+
- Commit messages are descriptive

## License

MIT

## Credits

Built with:
- [ripgrep](https://github.com/BurntSushi/ripgrep) for fast text replaceing
- Neovim's floating window API for the custom UI
