import Chroma
import Foundation

public struct ScribeChatInput: PrimitiveBlock {

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
  @MainActor public init(
    _ placeholder: String,
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
  }

  @MainActor public var expandsHorizontally: Bool { true }

  @MainActor public func sizeThatFits(_ proposal: Size, context: RenderContext) -> Size {
    let metrics = context.fontMetrics
    let count = layoutCache.lineCount(
      text: getText(), revision: revision(), columns: columns(width: proposal.width, metrics: metrics),
      limit: maxLines)
    let lineCount = min(maxLines, max(minLines, count))
    return Size(
      width: proposal.width,
      height: Float(lineCount) * metrics.lineAdvance * fontScale + 2 * padding + 2)
  }

  @MainActor public func draw(into drawList: inout DrawList, in rect: Rect, context: RenderContext) {
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

    let style = context.theme.textField
    drawList.fillRect(
      rect,
      color: state.editing ? style.editingBackground : state.hovered ? style.hoveredBackground : style.idleBackground)
    drawList.strokeRect(rect, width: style.borderWidth, color: state.editing ? style.editingBorder : style.border)

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
      drawList.text(placeholder, at: inner.origin, color: style.placeholder, scale: fontScale)
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
            drawList.text(rowText, at: origin, color: style.foreground, scale: fontScale)
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
        drawList.text(rowText, at: origin, color: style.foreground, scale: fontScale)
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
        color: style.caret)
    }
    drawList.popClip()
  }

  private func columns(width: Float, metrics: FontMetrics) -> Int {
    let usableWidth = max(metrics.cellAdvance * fontScale, width - 2 * padding - 2)
    return max(1, Int(usableWidth / (metrics.cellAdvance * fontScale)))
  }
}
