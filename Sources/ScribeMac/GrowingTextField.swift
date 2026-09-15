import Chroma
import Foundation

struct GrowingTextField: PrimitiveBlock {

  let id: WidgetID
  let placeholder: String
  let fontScale: Float
  let minLines: Int
  let maxLines: Int
  let padding: Float
  let layoutCache: ComposerTextLayoutCache
  let revision: () -> UInt64?
  let getText: @MainActor () -> String
  let onChange: @MainActor (String) -> Void
  let onNewline: @MainActor () -> Void
  let onEndEditing: @MainActor () -> CommandResult
  let onTextEvent: @MainActor (TextEditEvent, String) -> String?
  let textColor: Color
  let placeholderColor: Color
  let caretColor: Color
  let idleColor: Color
  let hoveredColor: Color
  let editingColor: Color
  let borderColor: Color
  let editingBorderColor: Color

  @MainActor init(
    _ placeholder: String,
    id: WidgetID,
    fontScale: Float,
    minLines: Int = 1,
    maxLines: Int = 6,
    padding: Float = 8,
    text: @escaping @MainActor () -> String,
    layoutCache: ComposerTextLayoutCache = ComposerTextLayoutCache(),
    revision: @escaping () -> UInt64? = { nil },
    onChange: @escaping @MainActor (String) -> Void,
    onNewline: @escaping @MainActor () -> Void,
    onEndEditing: @escaping @MainActor () -> CommandResult = { .ignored },
    onTextEvent: @escaping @MainActor (TextEditEvent, String) -> String? = { _, _ in nil }
  ) {
    self.layoutCache = layoutCache
    self.revision = revision
    self.id = id
    self.placeholder = placeholder
    self.fontScale = fontScale
    self.minLines = minLines
    self.maxLines = maxLines
    self.padding = padding
    self.getText = text
    self.onChange = onChange
    self.onNewline = onNewline
    self.onEndEditing = onEndEditing
    self.onTextEvent = onTextEvent
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
    let count = layoutCache.lineCount(
      text: getText(), revision: revision(), columns: columns(width: proposal.width, metrics: metrics),
      limit: maxLines)
    let lineCount = min(maxLines, max(minLines, count))
    return Size(
      width: proposal.width,
      height: Float(lineCount) * metrics.lineAdvance * fontScale + 2 * padding + 2)
  }

  @MainActor func draw(into drawList: inout DrawList, in rect: Rect, context: RenderContext) {
    let metrics = context.fontMetrics
    let layout = layoutCache.layout(
      text: getText(), revision: revision(), columns: columns(width: rect.size.width, metrics: metrics))
    let rows = layout.rows
    let visibleCount = min(maxLines, max(minLines, rows.count))
    let firstVisibleRow: (Int?) -> Int = { caret in
      let caretRow = layout.rowIndex(containing: caret)
      return max(0, min(max(0, rows.count - visibleCount), caretRow - visibleCount + 1))
    }
    let lineAdvance = metrics.lineAdvance * fontScale
    let cellWidth = metrics.cellAdvance * fontScale
    let textOrigin = Point(x: rect.minX + padding, y: rect.minY + padding + 1)
    let state = context.textInputState(
      id: id,
      in: rect,
      text: getText,
      onChange: onChange,
      onSubmit: { _ in onNewline() },
      onEndEditing: onEndEditing,
      onTextEvent: onTextEvent,
      pointerOffset: { point, viewportCaret in
        let visibleRow = Int(((point.y - textOrigin.y) / lineAdvance).rounded(.down))
        let rowIndex = max(0, min(rows.count - 1, firstVisibleRow(viewportCaret) + visibleRow))
        let row = rows[rowIndex]
        let column = Int(((point.x - textOrigin.x) / cellWidth).rounded(.toNearestOrAwayFromZero))
        return row.start + max(0, min(row.count, column))
      },
      verticalOffset: { offset, direction in
        let rowIndex = layout.rowIndex(containing: offset)
        let row = rows[rowIndex]
        let column = max(0, min(row.count, offset - row.start))
        let targetIndex = max(0, min(rows.count - 1, rowIndex + direction))
        let target = rows[targetIndex]
        return target.start + min(column, target.count)
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
    let caretRow = layout.rowIndex(containing: state.caretOffset)
    let firstVisible = firstVisibleRow(state.caretOffset)
    let visibleRows = rows.dropFirst(firstVisible).prefix(visibleCount)

    drawList.pushClip(inner)
    if getText().isEmpty && !state.editing {
      drawList.text(placeholder, at: inner.origin, color: placeholderColor, scale: fontScale)
    } else {
      for (visibleIndex, row) in visibleRows.enumerated() {
        let rowText = layout.text(for: row)
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
            drawList.text(rowText, at: origin, color: textColor, scale: fontScale)
            let selected = String(Array(rowText)[localStart..<localEnd])
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
        drawList.text(rowText, at: origin, color: textColor, scale: fontScale)
      }
    }
    if let caret = state.caretOffset, state.selectionRange == nil, context.caretVisible,
      caretRow >= firstVisible, caretRow < firstVisible + visibleCount
    {
      let row = rows[caretRow]
      let column = max(0, min(row.count, caret - row.start))
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

  private func columns(width: Float, metrics: FontMetrics) -> Int {
    let usableWidth = max(metrics.cellAdvance * fontScale, width - 2 * padding - 2)
    return max(1, Int(usableWidth / (metrics.cellAdvance * fontScale)))
  }
}
