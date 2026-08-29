import Chroma
import Foundation

/// A multiline, monospace text input that grows from one to `maxLines` visual
/// rows. Return is handled by `onNewline`; the macOS key monitor reserves
/// Command-Return for sending before Chroma receives the key event.
struct GrowingTextField: PrimitiveBlock {
  private struct Row {
    let text: String
    let start: Int
    let end: Int
  }

  let id: WidgetID
  let placeholder: String
  let fontScale: Float
  let minLines: Int
  let maxLines: Int
  let padding: Float
  let getText: () -> String
  let onChange: (String) -> Void
  let onNewline: () -> Void
  let textColor: Color
  let placeholderColor: Color
  let caretColor: Color
  let idleColor: Color
  let hoveredColor: Color
  let editingColor: Color
  let borderColor: Color
  let editingBorderColor: Color

  init(
    _ placeholder: String,
    id: WidgetID,
    fontScale: Float,
    minLines: Int = 1,
    maxLines: Int = 6,
    padding: Float = 8,
    text: @escaping () -> String,
    onChange: @escaping (String) -> Void,
    onNewline: @escaping () -> Void
  ) {
    self.id = id
    self.placeholder = placeholder
    self.fontScale = fontScale
    self.minLines = minLines
    self.maxLines = maxLines
    self.padding = padding
    self.getText = text
    self.onChange = onChange
    self.onNewline = onNewline
    self.textColor = .white
    self.placeholderColor = Color(r: 0.45, g: 0.45, b: 0.55, a: 1)
    self.caretColor = .white
    self.idleColor = Color(r: 0.14, g: 0.15, b: 0.22, a: 1)
    self.hoveredColor = Color(r: 0.17, g: 0.19, b: 0.28, a: 1)
    self.editingColor = Color(r: 0.10, g: 0.12, b: 0.20, a: 1)
    self.borderColor = Color(r: 0.22, g: 0.22, b: 0.32, a: 1)
    self.editingBorderColor = Color(r: 0.3, g: 0.6, b: 1.0, a: 1)
  }

  @MainActor var expandsHorizontally: Bool { true }

  @MainActor func sizeThatFits(_ proposal: Size, context: RenderContext) -> Size {
    let metrics = context.fontMetrics
    let rows = wrappedRows(text: getText(), width: proposal.width, metrics: metrics)
    let lineCount = min(maxLines, max(minLines, rows.count))
    return Size(
      width: proposal.width,
      height: Float(lineCount) * metrics.lineAdvance * fontScale + 2 * padding + 2)
  }

  @MainActor func draw(into drawList: inout DrawList, in rect: Rect, context: RenderContext) {
    let metrics = context.fontMetrics
    let rows = wrappedRows(text: getText(), width: rect.size.width, metrics: metrics)
    let visibleCount = min(maxLines, max(minLines, rows.count))
    let firstSelectableRow = max(0, rows.count - visibleCount)
    let lineAdvance = metrics.lineAdvance * fontScale
    let cellWidth = metrics.cellAdvance * fontScale
    let textOrigin = Point(x: rect.minX + padding, y: rect.minY + padding + 1)
    let state = context.textInputState(
      id: id,
      in: rect,
      text: getText(),
      onChange: onChange,
      onSubmit: { _ in onNewline() },
      pointerOffset: { point in
        let visibleRow = Int(((point.y - textOrigin.y) / lineAdvance).rounded(.down))
        let rowIndex = max(0, min(rows.count - 1, firstSelectableRow + visibleRow))
        let row = rows[rowIndex]
        let column = Int(((point.x - textOrigin.x) / cellWidth).rounded(.toNearestOrAwayFromZero))
        return row.start + max(0, min(row.text.count, column))
      },
      verticalOffset: { offset, direction in
        let rowIndex = rowIndex(containing: offset, rows: rows)
        let row = rows[rowIndex]
        let column = max(0, min(row.text.count, offset - row.start))
        let targetIndex = max(0, min(rows.count - 1, rowIndex + direction))
        let target = rows[targetIndex]
        return target.start + min(column, target.text.count)
      })
    if state.editing {
      ScribeRenderContext.activeTextInput = id
    } else if ScribeRenderContext.activeTextInput == id {
      ScribeRenderContext.activeTextInput = nil
    }

    drawList.fillRect(
      rect,
      color: state.editing ? editingColor : state.hovered ? hoveredColor : idleColor)
    drawList.strokeRect(rect, width: 1, color: state.editing ? editingBorderColor : borderColor)

    let inner = Rect(
      x: rect.minX + padding,
      y: rect.minY + padding + 1,
      width: max(0, rect.size.width - 2 * padding),
      height: max(0, rect.size.height - 2 * padding - 2))
    let caretRow = rowIndex(containing: state.caretOffset, rows: rows)
    let firstVisible = max(0, min(max(0, rows.count - visibleCount), caretRow - visibleCount + 1))
    let visibleRows = rows.dropFirst(firstVisible).prefix(visibleCount)

    drawList.pushClip(inner)
    if getText().isEmpty && !state.editing {
      drawList.text(placeholder, at: inner.origin, color: placeholderColor, scale: fontScale)
    } else {
      for (visibleIndex, row) in visibleRows.enumerated() {
        let origin = Point(x: inner.minX, y: inner.minY + Float(visibleIndex) * lineAdvance)
        if let selection = state.selectionRange {
          let start = max(row.start, selection.lowerBound)
          let end = min(row.end, selection.upperBound)
          if start < end {
            let localStart = start - row.start
            let localEnd = end - row.start
            let selectionRect = Rect(
              x: origin.x + Float(localStart) * cellWidth,
              y: origin.y,
              width: Float(localEnd - localStart) * cellWidth,
              height: lineAdvance)
            drawList.fillRect(selectionRect, color: context.theme.focus.selectionBackground)
            drawList.text(row.text, at: origin, color: textColor, scale: fontScale)
            let selected = String(Array(row.text)[localStart..<localEnd])
            drawList.pushClip(selectionRect)
            drawList.text(
              selected,
              at: Point(x: selectionRect.minX, y: origin.y),
              color: context.theme.focus.selectionForeground,
              scale: fontScale)
            drawList.popClip()
            continue
          }
        }
        drawList.text(row.text, at: origin, color: textColor, scale: fontScale)
      }
    }
    if let caret = state.caretOffset, state.selectionRange == nil, Self.caretVisible,
      caretRow >= firstVisible, caretRow < firstVisible + visibleCount
    {
      let row = rows[caretRow]
      let column = max(0, min(row.text.count, caret - row.start))
      drawList.fillRect(
        Rect(
          x: (inner.minX + Float(column) * cellWidth).rounded(),
          y: inner.minY + Float(caretRow - firstVisible) * lineAdvance - 1,
          width: max(1, fontScale),
          height: metrics.glyphHeight * fontScale + 2),
        color: caretColor)
    }
    drawList.popClip()
  }

  private func wrappedRows(text: String, width: Float, metrics: FontMetrics) -> [Row] {
    let usableWidth = max(metrics.cellAdvance * fontScale, width - 2 * padding - 2)
    let columns = max(1, Int(usableWidth / (metrics.cellAdvance * fontScale)))
    let characters = Array(text)
    var rows: [Row] = []
    var current = ""
    var start = 0

    for (index, character) in characters.enumerated() {
      if character == "\n" {
        rows.append(Row(text: current, start: start, end: index))
        current = ""
        start = index + 1
      } else {
        current.append(character)
        if current.count == columns {
          rows.append(Row(text: current, start: start, end: index + 1))
          current = ""
          start = index + 1
        }
      }
    }
    if !current.isEmpty || characters.isEmpty || characters.last == "\n" {
      rows.append(Row(text: current, start: start, end: characters.count))
    }
    return rows
  }

  private func rowIndex(containing caret: Int?, rows: [Row]) -> Int {
    guard let caret else { return max(0, rows.count - 1) }
    var result = 0
    for (index, row) in rows.enumerated() where caret >= row.start {
      result = index
    }
    return result
  }

  private static var caretVisible: Bool {
    Date().timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.2) < 0.72
  }
}
