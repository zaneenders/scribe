import Logging
import SlateCore
import _RopeModule

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
  private let log: Logger

  // MARK: - Init

  init(log: Logger) {
    self.log = log
    cursor = buffer.startIndex
  }

  // MARK: - Run loop

  /// Boots a fullscreen Slate session for the scratch-buffer editor.
  static func runFullscreen(log: Logger) async throws {
    try await SlateEditHost(log: log).run()
  }

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
              self.log.debug(
                "event=edit.quit source=ctrl-d mode=\(self.mode == .edit ? "edit" : "read")")
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
            case (.edit, .escape):
              self.log.debug("event=edit.mode.to-read source=escape")
              self.mode = .read
            case (.edit, .ctrl(3)):  // Ctrl+C → switch to read mode
              self.log.debug("event=edit.mode.to-read source=ctrl-c")
              self.mode = .read

            // ── Read mode ──
            case (.read, .enter):
              self.log.debug("event=edit.mode.to-edit source=enter")
              self.mode = .edit
            case (.read, .ctrl(3)):  // Ctrl+C → quit
              self.log.debug("event=edit.quit source=ctrl-c mode=read")
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
    buffer.removeSubrange(prev..<cursor)
    cursor = prev
  }

  // MARK: - Grid rendering

  private func renderGrid(cols: Int, rows: Int) -> TerminalCellGrid {
    let theme = CLITheme.default
    let fill = TerminalCell(
      glyph: " ", foreground: theme.inputText, background: theme.background, flags: [])
    var grid = TerminalCellGrid(cols: cols, rows: rows, filling: fill)

    let gutterCols = SlateChatRenderer.inputGutterColumns
    let text = String(buffer)
    let textWidth = max(0, cols &- gutterCols)
    let maxInputRows = min(8, max(1, rows &- 1))
    let (visualLines, inputRowCount) = SlateChatRenderer.prepareInputRows(
      text: text, textWidth: textWidth, maxRows: maxInputRows)

    let firstInputRow = rows &- inputRowCount

    // Fill input background region
    grid.blit(
      column: 0, row: firstInputRow, width: cols, height: inputRowCount,
      repeating: TerminalCell(
        glyph: " ", foreground: theme.inputText,
        background: theme.inputAreaBg, flags: []))

    // Delegate to shared input-row painter
    SlateChatRenderer.paintInputRows(
      into: &grid,
      startRow: firstInputRow,
      cols: cols,
      textWidth: textWidth,
      visualLines: visualLines,
      rowCount: inputRowCount,
      inputMode: mode,
      llmWaitAnimationFrame: 0,
      showSpinner: false,
      agentBusy: false,
      theme: theme)

    // Paint a top-bar hint line on row 0 if there's room
    if rows > inputRowCount {
      let hint =
        mode == .edit
        ? " Ctrl+C/Esc → read   Ctrl+D → quit"
        : " Enter → edit   Ctrl+C → quit"
      let hintSpan = TerminalStyledSpan(
        hint, foreground: theme.bannerLabel, background: theme.background)
      grid.blitSpans(column: 0, row: 0, maxWidth: cols, [hintSpan])
    }

    return grid
  }
}
