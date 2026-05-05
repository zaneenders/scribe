# Plan: Trivial Text Editing Movement + Modes

## Current State

The input system in `SlateChatHost` is minimal:

- **`inputBuffer`** — a flat `String`, characters appended at the end, backspace only removes the last char
- **Cursor** — always rendered at end-of-input via a `▏` glyph (no cursor position tracking)
- **Arrow Up/Down** — hard-wired to transcript scroll-back (not input editing)
- **Arrow Left/Right** — completely ignored (falls into `default: break`)
- **Escape** — not handled
- **Home/End** — control transcript viewport following, not cursor position
- No concept of editing "modes" at all

## Step 1: Scaffold `scribe _edit` with a copy of the current input UI

**Goal:** `scribe _edit` boots a Slate fullscreen session that renders *only* the input box from the chat UI — no transcript, no LLM, no tools. Start in edit mode: type, backspace, Shift+Enter for newlines. Ctrl+C exits to read mode; Enter from read mode re-enters edit mode. Ctrl+C in read mode (or Ctrl+D anywhere) quits. This proves the subcommand wiring, Slate lifecycle, render loop, and modal key routing are correct before any editor logic lands.

### 1a. `ScribeCLI.swift` — add the subcommand

```swift
// New file: Sources/ScribeCLI/ScribeEditCommand.swift
import ArgumentParser
import ScribeCore

struct _ScribeEditCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "_edit",
        abstract: "Experimental scratch buffer editor.",
        discussion: "Underscore prefix = internal/testing surface."
    )

    func run() async throws {
        try await SlateEdit.runFullscreen()
    }
}
```

Then register it in `ScribeCLI`:

```swift
@main struct ScribeCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "scribe",
        abstract: "Scribe coding agent",
        subcommands: [_ScribeEditCommand.self],
        defaultSubcommand: nil,  // no default; `scribe` alone still runs the implicit chat
        version: "0.0.1"
    )
    // ... existing run() unchanged
}
```

**Design note:** `ScribeCLI.run()` is the implicit default command when no subcommand is given. ArgumentParser handles this — the `_edit` subcommand only fires when `scribe _edit` is typed. The existing `scribe` chat path is untouched.

### 1b. `SlateEdit.swift` — bootstrap the Slate session

This is a minimal analogue of `SlateChat.runFullscreen()`:

```swift
// New file: Sources/ScribeCLI/SlateEdit/SlateEdit.swift
import SlateCore

enum SlateEdit {
    static func runFullscreen() async throws {
        try await Task { @MainActor in
            try await SlateEditHost().run()
        }.value
    }
}
```

### 1c. `SlateEditHost.swift` — the editor host

```swift
// New file: Sources/ScribeCLI/SlateEdit/SlateEditHost.swift
import SlateCore
import _RopeModule

enum EditMode {
    case read    // d=left, f=up, j=down, k=right, Enter→edit, Ctrl+C→quit
    case edit    // typing inserts, arrows move, Ctrl+C→read
}

@MainActor
final class SlateEditHost {
    private var buffer = BigString()
    private var cursor = BigString.Index.startOfFirstChunk  // or buffer.startIndex
    private var keyDecoder = TerminalKeyDecoder()
    private var mode = EditMode.edit

    init() {}

    func run() async throws {
        var slate = try Slate()
        await slate.start(
            prepare: { $0.requestRender() },
            onEvent: { slate, event in
                switch event {
                case .resize:  slate.refreshWindowSize()
                case .external: break
                case .stdinBytes(let chunk):
                    if chunk.isEmpty { return .stop }
                    var stop = false
                    self.keyDecoder.decode(chunk) { key in
                        switch (self.mode, key) {
                        case (_, .ctrl(4)):                     stop = true
                        case (.edit, .character(let ch)):       self.insertChar(ch)
                        case (.edit, .backspace):               self.deleteBackward()
                        case (.edit, .shiftEnter):              self.insertChar("\n")
                        case (.edit, .ctrl(3)):                 self.mode = .read
                        case (.read, .enter):                   self.mode = .edit
                        case (.read, .ctrl(3)):                 stop = true
                        default: break
                        }
                    }
                    if stop { return .stop }
                    slate.enscribe(grid: self.renderGrid(cols: slate.cols, rows: slate.rows))
                }
                return .continue
            }
        )
    }
}
```

**Buffer ops** are cursor-relative from day one: `insertChar` inserts at `cursor` and advances it, `deleteBackward` moves cursor back then removes. The `renderGrid` helper builds the same `you: ` input box as `SlateChatRenderer.paintInputRows`, with the mode label prepended and the `▏` cursor placed at the computed visual position rather than always at end.

**New dependency:** `_RopeModule` from swift-collections (add to `Package.swift` dependencies + ScribeCLI target).

### 1d. What this gives us

```
$ swift run scribe _edit
┌─────────────────────────────────────────────┐
│                                             │  ← full terminal, no transcript
│                                             │
│                                             │
│                                             │
│                                             │
│ you: hello world▏                           │  ← just the input box
└─────────────────────────────────────────────┘
```

Mode toggling works: Ctrl+C exits edit → read, Enter enters edit, Ctrl+C in read (or Ctrl+D anywhere) quits. The entire thing is ~70 lines of host code with no edits to `SlateChatHost` or `SlateChatRenderer`.

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

## Step 4: Merge into chat input

Once the editor core is stable, `SlateChatHost` adopts the same buffer/mode primitives for its input box. Arrow keys in the chat become mode-dependent (edit→cursor movement, read→transcript scrolling). The `_edit` subcommand remains as a standalone testbed.

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
