import Chroma
import Foundation
import GhosttyVt

/// A small terminal model backed by libghostty-vt.
///
/// `GhosttyTerminal` owns Ghostty's VT state machine and exposes it as a Chroma
/// block. It is intentionally transport-agnostic: feed bytes received from a
/// PTY with `write(_:)`, and use `onInput` to forward keyboard input to the PTY.
public final class GhosttyTerminal: @unchecked Sendable {
  // libghostty and the reusable render iterators are not safe for concurrent access.
  // Keep every access to their state behind this lock so the model can safely be
  // written by a transport task while the UI produces a render snapshot.
  private let stateLock = NSLock()
  private var terminal: OpaquePointer?
  private var formatter: OpaquePointer?
  private var renderState: OpaquePointer?
  private var rowIterator: OpaquePointer?
  private var rowCells: OpaquePointer?
  private var columns: UInt16
  private var rows: UInt16

  private var inputHandler: ((String) -> Void)?
  private var resizeHandler: ((UInt16, UInt16) -> Void)?

  /// Called for text entered while the terminal is focused.
  public var onInput: ((String) -> Void)? {
    get { withStateLock { inputHandler } }
    set { withStateLock { inputHandler = newValue } }
  }

  /// Called after the terminal grid changes size so a PTY can update TIOCSWINSZ.
  public var onResize: ((UInt16, UInt16) -> Void)? {
    get { withStateLock { resizeHandler } }
    set { withStateLock { resizeHandler = newValue } }
  }

  @discardableResult
  private func withStateLock<Result>(_ body: () throws -> Result) rethrows -> Result {
    stateLock.lock()
    defer { stateLock.unlock() }
    return try body()
  }

  public init(columns: UInt16 = 80, rows: UInt16 = 24) throws {
    self.columns = max(1, columns)
    self.rows = max(1, rows)

    var terminal: OpaquePointer?
    guard ghostty_terminal_new(nil, &terminal, self.columns, self.rows) == GHOSTTY_SUCCESS,
      let terminal
    else {
      throw GhosttyTerminalError.initializationFailed
    }
    self.terminal = terminal

    var scrollbackLines: Int = 10_000
    guard ghostty_terminal_set(
      terminal, GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_LINES, &scrollbackLines) == GHOSTTY_SUCCESS
    else {
      ghostty_terminal_free(terminal)
      self.terminal = nil
      throw GhosttyTerminalError.initializationFailed
    }

    var options = GhosttyFormatterTerminalOptions()
    options.size = MemoryLayout<GhosttyFormatterTerminalOptions>.size
    options.emit = GHOSTTY_FORMATTER_FORMAT_PLAIN
    options.trim = true

    var formatter: OpaquePointer?
    guard ghostty_formatter_terminal_new(nil, &formatter, terminal, options) == GHOSTTY_SUCCESS,
      let formatter
    else {
      ghostty_terminal_free(terminal)
      self.terminal = nil
      throw GhosttyTerminalError.formatterInitializationFailed
    }
    self.formatter = formatter

    var renderState: OpaquePointer?
    guard ghostty_render_state_new(nil, &renderState) == GHOSTTY_SUCCESS,
      let renderState
    else {
      ghostty_formatter_free(formatter)
      ghostty_terminal_free(terminal)
      self.formatter = nil
      self.terminal = nil
      throw GhosttyTerminalError.renderStateInitializationFailed
    }
    self.renderState = renderState

    var rowIterator: OpaquePointer?
    var rowCells: OpaquePointer?
    guard ghostty_render_state_row_iterator_new(nil, &rowIterator) == GHOSTTY_SUCCESS,
      ghostty_render_state_row_cells_new(nil, &rowCells) == GHOSTTY_SUCCESS,
      let rowIterator, let rowCells
    else {
      if let rowIterator { ghostty_render_state_row_iterator_free(rowIterator) }
      if let rowCells { ghostty_render_state_row_cells_free(rowCells) }
      ghostty_render_state_free(renderState)
      ghostty_formatter_free(formatter)
      ghostty_terminal_free(terminal)
      self.renderState = nil
      self.formatter = nil
      self.terminal = nil
      throw GhosttyTerminalError.renderStateInitializationFailed
    }
    self.rowIterator = rowIterator
    self.rowCells = rowCells
  }

  deinit {
    if let rowCells { ghostty_render_state_row_cells_free(rowCells) }
    if let rowIterator { ghostty_render_state_row_iterator_free(rowIterator) }
    if let renderState { ghostty_render_state_free(renderState) }
    if let formatter { ghostty_formatter_free(formatter) }
    if let terminal { ghostty_terminal_free(terminal) }
  }

  /// Feed VT-encoded output into the terminal.
  public func write(_ text: String) {
    write(Data(text.utf8))
  }

  /// Feed VT-encoded output into the terminal.
  public func write(_ data: Data) {
    guard !data.isEmpty else { return }
    withStateLock {
      guard let terminal else { return }
      data.withUnsafeBytes { bytes in
        guard let baseAddress = bytes.baseAddress else { return }
        ghostty_terminal_vt_write(
          terminal,
          baseAddress.assumingMemoryBound(to: CChar.self),
          bytes.count
        )
      }
    }
  }

  public func reset() {
    withStateLock {
      guard let terminal else { return }
      ghostty_terminal_reset(terminal)
    }
  }

  /// A plain-text snapshot of Ghostty's current active screen.
  public var plainText: String {
    lines().joined(separator: "\n")
  }

  /// Return a Chroma block that renders the current active screen.
  ///
  /// `onEditingChanged` reports whenever the view gains or loses text-editing
  /// focus so hosts can route auxiliary input (for example application
  /// commands) only while the terminal is live.
  public func view(
    id: WidgetID = WidgetID("ghostty.terminal"),
    fontScale: Float = 0.5,
    colors: GhosttyTerminalColors = GhosttyTerminalColors(),
    onEditingChanged: (@MainActor (Bool) -> Void)? = nil
  ) -> GhosttyTerminalView {
    GhosttyTerminalView(
      model: self, id: id, fontScale: fontScale, colors: colors,
      onEditingChanged: onEditingChanged)
  }

  /// Scroll the viewport through retained history. Negative values move up.
  public func scroll(lines: Int) {
    guard lines != 0 else { return }
    withStateLock {
      guard let terminal else { return }
      var viewport = GhosttyTerminalScrollViewport()
      viewport.tag = GHOSTTY_SCROLL_VIEWPORT_DELTA
      viewport.value.delta = lines
      ghostty_terminal_scroll_viewport(terminal, viewport)
    }
  }

  fileprivate func resize(columns: UInt16, rows: UInt16) {
    let columns = max(1, columns)
    let rows = max(1, rows)
    let handler: ((UInt16, UInt16) -> Void)? = withStateLock {
      guard columns != self.columns || rows != self.rows, let terminal else { return nil }
      guard ghostty_terminal_resize(terminal, columns, rows, 1, 1) == GHOSTTY_SUCCESS else { return nil }
      self.columns = columns
      self.rows = rows
      return resizeHandler
    }
    handler?(columns, rows)
  }

  fileprivate struct Cell {
    let text: String
    let foreground: Color
  }

  fileprivate func styledRows(fallback: Color) -> [[Cell]] {
    withStateLock { styledRowsUnlocked(fallback: fallback) }
  }

  private func styledRowsUnlocked(fallback: Color) -> [[Cell]] {
    guard let terminal, let renderState, let rowIterator, let rowCells,
      ghostty_render_state_update(renderState, terminal) == GHOSTTY_SUCCESS,
      ghostty_render_state_get(
        renderState, GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR, &self.rowIterator) == GHOSTTY_SUCCESS
    else { return [] }

    var result: [[Cell]] = []
    while ghostty_render_state_row_iterator_next(rowIterator) {
      guard ghostty_render_state_row_get(
        rowIterator, GHOSTTY_RENDER_STATE_ROW_DATA_CELLS, &self.rowCells) == GHOSTTY_SUCCESS
      else { continue }

      var row: [Cell] = []
      while ghostty_render_state_row_cells_next(rowCells) {
        var length: UInt32 = 0
        guard ghostty_render_state_row_cells_get(
          rowCells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_LEN, &length) == GHOSTTY_SUCCESS
        else { continue }
        if length == 0 {
          row.append(Cell(text: " ", foreground: fallback))
          continue
        }

        var codepoints = [UInt32](repeating: 0, count: Int(length))
        let graphemeResult = codepoints.withUnsafeMutableBufferPointer { buffer in
          ghostty_render_state_row_cells_get(
            rowCells,
            GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_BUF,
            buffer.baseAddress
          )
        }
        guard graphemeResult == GHOSTTY_SUCCESS else { continue }
        let text = String(codepoints.compactMap(UnicodeScalar.init).map(Character.init))

        var rgb = GhosttyColorRgb()
        let color: Color
        if ghostty_render_state_row_cells_get(
          rowCells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_FG_COLOR, &rgb) == GHOSTTY_SUCCESS
        {
          color = Color(
            r: Float(rgb.r) / 255, g: Float(rgb.g) / 255,
            b: Float(rgb.b) / 255, a: 1)
        } else {
          color = fallback
        }
        row.append(Cell(text: text, foreground: color))
      }
      while row.last?.text == " " { row.removeLast() }
      result.append(row)
    }
    return result
  }

  fileprivate func cursor() -> (column: UInt16, row: UInt16, visible: Bool)? {
    withStateLock { cursorUnlocked() }
  }

  private func cursorUnlocked() -> (column: UInt16, row: UInt16, visible: Bool)? {
    guard let terminal, let renderState,
      ghostty_render_state_update(renderState, terminal) == GHOSTTY_SUCCESS
    else { return nil }

    var visible = false
    var inViewport = false
    guard ghostty_render_state_get(
      renderState, GHOSTTY_RENDER_STATE_DATA_CURSOR_VISIBLE, &visible) == GHOSTTY_SUCCESS,
      ghostty_render_state_get(
        renderState, GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_HAS_VALUE, &inViewport) == GHOSTTY_SUCCESS,
      inViewport
    else { return nil }

    var column: UInt16 = 0
    var row: UInt16 = 0
    guard ghostty_render_state_get(
      renderState, GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_X, &column) == GHOSTTY_SUCCESS,
      ghostty_render_state_get(
        renderState, GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_Y, &row) == GHOSTTY_SUCCESS
    else { return nil }
    return (column, row, visible)
  }

  fileprivate func lines() -> [String] {
    withStateLock { linesUnlocked() }
  }

  private func linesUnlocked() -> [String] {
    guard let formatter else { return [] }

    var buffer: UnsafeMutablePointer<UInt8>?
    var length = 0
    guard ghostty_formatter_format_alloc(formatter, nil, &buffer, &length) == GHOSTTY_SUCCESS,
      let buffer
    else { return [] }
    defer { ghostty_free(nil, buffer, length) }

    let text = String(decoding: UnsafeBufferPointer(start: buffer, count: length), as: UTF8.self)
    var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    if lines.last == "" { lines.removeLast() }
    return lines
  }
}

public enum GhosttyTerminalError: Error, Equatable {
  case initializationFailed
  case formatterInitializationFailed
  case renderStateInitializationFailed
}

/// Palette for the terminal view, decoupled from any particular app theme.
public struct GhosttyTerminalColors: Sendable {
  public var background: Color
  public var foreground: Color
  public var cursor: Color
  public var focusedBorder: Color

  public init(
    background: Color = Color(r: 0.08, g: 0.09, b: 0.13, a: 1),
    foreground: Color = Color(r: 0.92, g: 0.93, b: 0.97, a: 1),
    cursor: Color = Color(r: 0.3, g: 0.6, b: 1.0, a: 1),
    focusedBorder: Color = Color(r: 0.3, g: 0.6, b: 1.0, a: 1)
  ) {
    self.background = background
    self.foreground = foreground
    self.cursor = cursor
    self.focusedBorder = focusedBorder
  }
}

public struct GhosttyTerminalView: PrimitiveBlock {
  fileprivate let model: GhosttyTerminal
  public let id: WidgetID
  public let fontScale: Float
  public let colors: GhosttyTerminalColors
  public let onEditingChanged: (@MainActor (Bool) -> Void)?

  fileprivate init(
    model: GhosttyTerminal,
    id: WidgetID,
    fontScale: Float,
    colors: GhosttyTerminalColors,
    onEditingChanged: (@MainActor (Bool) -> Void)?
  ) {
    self.model = model
    self.id = id
    self.fontScale = fontScale
    self.colors = colors
    self.onEditingChanged = onEditingChanged
  }

  public var expandsHorizontally: Bool { true }
  public var expandsVertically: Bool { true }

  public func sizeThatFits(_ proposal: Size, context: RenderContext) -> Size { proposal }

  public func draw(into drawList: inout DrawList, in rect: Rect, context: RenderContext) {
    let metrics = context.fontMetrics
    let effectiveScale = fontScale * context.textScale
    let cellWidth = max(1, metrics.cellAdvance * effectiveScale)
    let lineHeight = max(1, metrics.lineAdvance * effectiveScale)
    let columns = UInt16(clamping: max(1, Int((rect.size.width - 16) / cellWidth)))
    let rows = UInt16(clamping: max(1, Int((rect.size.height - 12) / lineHeight)))
    model.resize(columns: columns, rows: rows)

    let state = context.textInputState(
      id: id,
      in: rect,
      text: "",
      onChange: { text in
        guard !text.isEmpty else { return }
        model.onInput?(text)
      },
      onSubmit: { _ in model.onInput?("\r") }
    )
    onEditingChanged?(state.editing)

    if rect.contains(context.input.pointerPosition), context.input.scrollDelta.y != 0 {
      let lines = Int((context.input.scrollDelta.y / lineHeight).rounded())
      model.scroll(lines: lines == 0 ? (context.input.scrollDelta.y > 0 ? -1 : 1) : -lines)
    }

    if state.editing {
      for event in context.input.textEvents {
        switch event {
        case .backspace:
          model.onInput?("\u{7F}")
        case .deleteForward:
          model.onInput?("\u{1B}[3~")
        case .moveCaretLeft:
          model.onInput?("\u{1B}[D")
        case .moveCaretRight:
          model.onInput?("\u{1B}[C")
        case .moveCaretToStart:
          model.onInput?("\u{1B}[H")
        case .moveCaretToEnd:
          model.onInput?("\u{1B}[F")
        default:
          break
        }
      }
    }

    drawList.fillRect(rect, color: colors.background)
    drawList.pushClip(rect)
    for (rowIndex, row) in model.styledRows(fallback: colors.foreground)
      .prefix(Int(rows)).enumerated()
    {
      var column = 0
      var run = ""
      var runColor: Color?

      func flushRun() {
        guard !run.isEmpty, let runColor else { return }
        drawList.text(
          run,
          at: Point(
            x: rect.minX + 8 + Float(column - run.count) * cellWidth,
            y: rect.minY + 6 + Float(rowIndex) * lineHeight),
          color: runColor,
          scale: effectiveScale
        )
        run = ""
      }

      for cell in row {
        if let runColor, runColor != cell.foreground { flushRun() }
        runColor = cell.foreground
        run += cell.text
        column += 1
      }
      flushRun()
    }
    if state.editing,
      let cursor = model.cursor(), cursor.visible,
      Date().timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1) < 0.55
    {
      let cursorRect = Rect(
        x: rect.minX + 8 + Float(cursor.column) * cellWidth,
        y: rect.minY + 6 + Float(cursor.row) * lineHeight,
        width: max(2, cellWidth),
        height: lineHeight
      )
      drawList.fillRect(cursorRect, color: colors.cursor)
    }
    drawList.popClip()

    if state.editing {
      drawList.strokeRect(rect, width: 1, color: colors.focusedBorder)
    }
  }
}
