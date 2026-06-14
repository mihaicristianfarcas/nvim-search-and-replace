# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] - 2026-06-14

First tagged release.

### Features

- Async live search via streaming `ripgrep` JSON output, with live match-count progress.
- Side-by-side before/after preview with precise match highlighting and jump-to-match.
- Selective replacement (current item, visual-mode selection, or all matches) with exact-match validation before writing.
- Full **multiline** match replacement (`multiline = true`): matching, replacement, and before/after preview for patterns that span lines.
- Undo/redo of replacements with a persistent history across sessions, validated against the current file content so drifted files are skipped rather than clobbered.
- Configurable `sort` option: `"path"` (stable ordering) or `false`/`"none"` (faster, unordered, parallel) on large repositories.
- Non-blocking replacements: edit computation is chunked across event-loop ticks and disk writes run off-thread, so large operations don't freeze the editor.
- Configurable keymaps, debounce, max results, and max file size.
- `:checkhealth` support.

### Safety / correctness

- Preserves each file's line endings (LF/CRLF) and trailing-newline state on write.
- Skips files that are open in a buffer with unsaved changes (matched by symlink-resolved path).
- Confirms before "Replace ALL" when results were truncated at `max_results`.

[0.1.0]: https://github.com/mihaicristianfarcas/nvim-search-and-replace/releases/tag/v0.1.0
