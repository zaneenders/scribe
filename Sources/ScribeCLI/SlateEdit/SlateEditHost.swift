import _RopeModule
import SlateCore

// MARK: - Edit mode

enum EditMode {
  /// Navigation mode: keys move the cursor, Enter switches to edit mode,
  /// Ctrl+C quits.
  case read
  /// Typing mode: keys insert characters, Ctrl+C switches to read mode.
  case edit
}

// MARK: - Host

/// A minimal Slate host for the `scribe _edit` scratch buffer.
///
/// Renders only an input box (no transcript, no LLM, no tools).  Supports two
/// modes toggled with Ctrl+C / Enter and a cursor-relative `BigString` buffer.
@MainActor
internal final class SlateEditHost {

  // MARK: - State

  private var buffer = BigString()
  private var cursor: BigString.Index
  private var keyDecoder = TerminalKeyDecoder()
  private var mode = EditMode.edit

  // MARK: - Init

  init() {
    cursor = buffer.startIndex
  }

  // MARK: - Run loop

  func run() async throws {
    var slate = try Slate()
    await slate.start(
      prepare: { wake in
        wake.requestRender()
      },
      onEvent: { [self] slate, event in
        switch event {
        case .resize:
          slate.refreshWindowSize()

        case .external:
          break

        case .stdinBytes(let chunk):
          if chunk.isEmpty { return .stop }
          var stop = false
          self.keyDecoder.decode(chunk) { key in
            switch (self.mode, key) {

            // ── Always-available keys ──
            case (_, .ctrl(4)):  // Ctrl+D — quit from either mode
              stop = true

            // ── Edit mode ──
            case (.edit, .character(let ch)):
              self.insertChar(ch)
            case (.edit, .backspace):
              self.deleteBackward()
            case (.edit, .shiftEnter):
              self.insertChar("\n")
            case (.edit, .enter):
              self.insertChar("\n")
            case (.edit, .ctrl(3)):  // Ctrl+C → switch to read mode
              self.mode = .read

            // ── Read mode ──
            case (.read, .enter):
              self.mode = .edit
            case (.read, .ctrl(3)):  // Ctrl+C → quit
              stop = true

            default:
              break
            }
          }
          if stop { return .stop }
        }

        // Render on every event — resize, external (initial wake), and stdin.
        slate.enscribe(grid: self.renderGrid(cols: slate.cols, rows: slate.rows))
        return .continue
      })
  }

  // MARK: - Buffer operations (cursor-relative)

  private func insertChar(_ ch: Character) {
    buffer.insert(contentsOf: String(ch), at: cursor)
    cursor = buffer.index(after: cursor)
  }

  private func deleteBackward() {
    guard cursor > buffer.startIndex else { return }
    let prev = buffer.index(before: cursor)
    buffer.removeSubrange(prev ..< cursor)
    cursor = prev
  }

  // MARK: - Grid rendering

  private let inputGutterColumns = 6  // "EDIT: " / "READ: " width

  private func renderGrid(cols: Int, rows: Int) -> TerminalCellGrid {
    let theme = CLITheme.default
    let fill = TerminalCell(
      glyph: " ", foreground: theme.inputText, background: theme.background, flags: [])
    var grid = TerminalCellGrid(cols: cols, rows: rows, filling: fill)

    let text = String(buffer)
    let textWidth = max(0, cols &- inputGutterColumns)
    let allVisualLines = TranscriptLayout.inputVisualLines(from: text, textWidth: textWidth)

    let maxInputRows = min(8, max(1, rows &- 1))
    let inputRowCount: Int
    let visualLines: [String]

    if allVisualLines.isEmpty {
      visualLines = [""]
      inputRowCount = 1
    } else {
      let needsExtraCursorRow =
        allVisualLines.last.map({ $0.count >= textWidth && textWidth > 0 }) ?? false
      var lines = allVisualLines
      if needsExtraCursorRow {
        lines.append("")
      }
      inputRowCount = min(maxInputRows, max(1, lines.count))
      visualLines =
        lines.count > inputRowCount
        ? Array(lines.suffix(inputRowCount))
        : lines + Array(repeating: "", count: max(0, inputRowCount &- lines.count))
    }

    let firstInputRow = rows &- inputRowCount

    // Fill input background region
    grid.blit(
      column: 0, row: firstInputRow, width: cols, height: inputRowCount,
      repeating: TerminalCell(
        glyph: " ", foreground: theme.inputText,
        background: theme.inputAreaBg, flags: []))

    // Paint input rows
    let modeLabel = mode == .edit ? "EDIT: " : "READ: "
    let modeColor =
      mode == .edit ? theme.userPrefix : theme.scribePrefix
    let gutter = String(repeating: " ", count: inputGutterColumns)
    let bg = theme.inputAreaBg

    for lineIdx in 0 ..< inputRowCount {
      let row = firstInputRow &+ lineIdx
      guard row >= 0, row < grid.rows else { break }
      let onLastRow = lineIdx == inputRowCount &- 1

      var spans: [TerminalStyledSpan] = []
      if lineIdx == 0 {
        spans.append(TerminalStyledSpan(modeLabel, foreground: modeColor, background: bg))
        if lineIdx < visualLines.count, textWidth > 0 {
          spans.append(
            TerminalStyledSpan(
              String(visualLines[lineIdx].prefix(textWidth)),
              foreground: theme.inputText, background: bg))
        }
        if onLastRow {
          spans.append(
            TerminalStyledSpan("▏", foreground: theme.inputCursor, background: bg))
        }
      } else {
        spans.append(TerminalStyledSpan(gutter, foreground: theme.inputGutter, background: bg))
        if lineIdx < visualLines.count, textWidth > 0 {
          spans.append(
            TerminalStyledSpan(
              String(visualLines[lineIdx].prefix(textWidth)),
              foreground: theme.inputText, background: bg))
        }
        if onLastRow {
          spans.append(
            TerminalStyledSpan("▏", foreground: theme.inputCursor, background: bg))
        }
      }
      grid.blitSpans(column: 0, row: row, maxWidth: cols, spans)
    }

    // Paint a top-bar hint line on row 0 if there's room
    if rows > inputRowCount {
      let hint = mode == .edit
        ? " Ctrl+C → read   Ctrl+D → quit"
        : " Enter → edit   Ctrl+C → quit"
      let hintSpan = TerminalStyledSpan(
        hint, foreground: theme.bannerLabel, background: theme.background)
      grid.blitSpans(column: 0, row: 0, maxWidth: cols, [hintSpan])
    }

    return grid
  }
}
