# Plan: Modal Text Editing for Chat Input

## Current State

The input system in `SlateChatHost` now has modal editing (edit/read modes) integrated directly into the chat input box. The standalone `_edit` subcommand has been removed — all editing happens in-place during chat sessions.

### Mode toggling

| Key | From | To | Notes |
|-----|------|----|-------|
| `Ctrl+C` | edit | read | Switch to read (navigation) mode |
| `Escape` | edit | read | Same as `Ctrl+C` |
| `Enter` | read | edit | Enter typing mode at the current cursor |
| `Ctrl+C` | read | — | Quit |
| `Ctrl+D` | either | — | Quit from anywhere |

---

## Step 2: Flesh out read-mode navigation

Read mode gets movement keys:

| Key | Action |
|-----|--------|
| `d` / `.arrowLeft` | Move cursor left |
| `k` / `.arrowRight` | Move cursor right |
| `i` | Enter edit mode at cursor |
| `a` | Cursor right, enter edit mode |
| `I` | Cursor to start of visual line, enter edit mode |
| `A` | Cursor to end of line, enter edit mode |
| `o` | Insert newline after current, enter edit mode |
| `O` | Insert newline before current, enter edit mode |

Vertical movement (`f` = up, `j` = down) lands in Step 3 once visual-line mapping is in place. Edit mode gets arrow keys wired to cursor movement.

---

## Step 3: Visual-line-aware cursor movement

Up/Down arrows (and `f`/`j` in read mode) move the cursor to the previous/next visual line at the attempted same column. Needs the `(buffer, cursor, textWidth) → (visualRow, visualCol)` mapping from the renderer, inverted to go from `(visualRow ± 1, visualCol) → buffer index`.

---

## Step 4: Polish chat input integration

The modal editor is now directly integrated into `SlateChatHost`'s input box. Arrow keys in the chat are mode-dependent (edit→cursor movement, read→transcript scrolling).

---

## Testing Strategy

Most of the editor logic is pure functions — testable without a TTY.

### Unit-testable (no Slate/TTY needed)

| Surface | What to test |
|---------|-------------|
| **Buffer ops** | Insert char at cursor (start, middle, end, empty buffer). Delete before/after cursor (boundaries). Multi-byte characters. Newlines. |
| **Cursor movement** | Left/right at buffer edges. Up/down across wrapped visual lines. Home/End. Word boundaries (later). |
| **Mode transitions** | Insert → normal (Escape). Normal → insert (`i`, `a`, `o`, `O`). Mode indicator string. Normal-mode `r` (replace single char) returns to normal. |
| **Visual-line mapping** | Given `(BigString, BigString.Index, textWidth)`, compute (visualRow, visualCol). Empty buffer. Single long wrapped line. Trailing newline. Cursor on newline character. |
| **Key routing table** | Exhaustive: for each `(EditMode, TerminalKeyEvent)` pair, assert the expected action enum (`moveCursor(.left)`, `switchMode(.insert)`, `scrollTranscript(.up)`, `insertChar("x")`, `noop`, etc.). This is a pure function and can be table-driven. |

### TTY-needed tests

| Surface | How |
|---------|-----|
| **Render output** | Build a `TerminalCellGrid` from a known buffer+cursor+theme and snapshot the cell grid (or compare spans). Can run on any platform since `TerminalCellGrid` is just data. |
| **Full integration** | Boot `Slate` in a CI-compatible pseudo-tty (or manually). Needed for resize behavior, paste, and CSI edge cases — defer until the unit-tested core is stable. |


## Slate Notes & Potential Gotchas

### Missing `.delete` key

`TerminalKeyEvent` has no `.delete` case. The Delete key sends `\e[3~` which the decoder emits as `.unknown([0x1B, 0x5B, 0x33, 0x7E])`. Options:

- **Handle `.unknown` in the host** — match the byte pattern and treat as forward-delete. Quick but fragile.
- **Contribute `.delete` to slate** — add the case to the enum and decode `\e[3~` in `emitCSI`. Cleaner long-term. The slate source lives at `../slate` relative to the scribe project; it's the same author's repo and can be updated in parallel.

> **First draft:** `scribe#edit` branch on slate (pushed). Adds `.delete` case to `TerminalKeyEvent` + decodes `\e[3~` in `emitCSI`. Also drops `.swiftLanguageMode(.v6)` from Package.swift targets (build fix) and removes LICENSE.

### Bracketed paste

Slate enables bracketed paste by default (`CSI.bracketedPasteOn` in `writeRedrawBootstrapCSI`). The decoder emits `.bracketedPasteStart` / `.bracketedPasteEnd`. Our editor host should track `inPaste` (like `SlateChatHost` does) and:

- In edit mode: paste newlines stay literal, backspace is suppressed during paste (avoids mangling pasted data)
- In read mode: paste should likely be rejected or treated as a no-op (pasting into normal mode would insert literal `i`/`d`/`j`/`k` characters which is almost never what the user wants)

### Resize polling

`TerminalWakePump` polls `TIOCGWINSZ` every 100ms and emits `.resize`. The plan already calls `slate.refreshWindowSize()` on resize, which updates `slate.cols`/`slate.rows` and resizes the presenter's encode buffer. After a resize, cursor-to-visual-line mapping must be recomputed since `textWidth` changes.

### Grid dimensions capped at 512×512

`TTY.windowSize()` clamps to 512 columns/rows by default. This is more than enough for an input box (max 8 rows). If the editor later grows to full-file editing with many rows, this cap is still fine — it just means extremely large terminals (>512 cols) will use 512 for rendering calculations.

### `TerminalCellFlags` is minimal

Only `.bold` exists today. No italic, underline, dim, or inverse. This is fine for the editor — we only need bold (for the cursor or mode indicator emphasis) and normal text.

### `Slate` is `~Copyable`

`Slate.start(onEvent:)` passes `inout Self` to the closure. The host (`SlateEditHost`) is captured as a reference (`final class`), which works cleanly. The `renderWake` is `ExternalWake?` — set in `prepare`, used to request frames from external sources (not needed for the editor since all rendering is driven by stdin).

### Slate source repo

The slate dependency in scribe's `Package.swift` pins to revision `96149cd`. Slate's actual development source is at `../slate` (same author). If we add `.delete` to `TerminalKeyEvent`, we can update the pin after pushing to slate's main branch.

### Cursor hiding

Slate calls `CSI.curHide` during bootstrap and `CSI.curShow` on teardown. The terminal cursor is invisible while the fullscreen session is active — all cursor rendering is done in-application via the `▏` glyph in the cell grid. No conflict with the terminal's own cursor.
