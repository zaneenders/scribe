import Chroma
import Foundation

func sanitizeASCII(_ text: String) -> String {
  var out = String()
  out.reserveCapacity(text.count)
  for scalar in text.unicodeScalars {
    switch scalar {
    case "\t": out += "    "
    case "\n", "\r": out += "\n"
    case "\u{2018}", "\u{2019}", "\u{201A}", "\u{201B}": out += "'"
    case "\u{201C}", "\u{201D}", "\u{201E}": out += "\""
    case "\u{2013}", "\u{2014}", "\u{2015}": out += "--"
    case "\u{2026}": out += "..."
    case "\u{2190}": out += "<-"
    case "\u{2192}": out += "->"
    case "\u{2191}": out += "^"
    case "\u{2193}": out += "v"
    case "\u{2022}", "\u{00B7}", "\u{25CF}": out += "*"
    case "\u{00A0}": out += " "
    default:
      if (0x20...0x7E).contains(scalar.value) || (0x2500...0x257F).contains(scalar.value) {
        out.unicodeScalars.append(scalar)
      } else if scalar.properties.generalCategory != .nonspacingMark {
        out += "?"
      }
    }
  }
  return out
}

enum MDBlock: Equatable {
  case paragraph(String)
  case code(language: String?, code: String)
  case heading(level: Int, text: String)
  case listItem(marker: String, text: String, depth: Int)
  case quote(String)
  case rule
}

func segmentMarkdown(_ source: String) -> [MDBlock] {
  var blocks: [MDBlock] = []
  var inCode = false
  var codeLanguage: String? = nil
  var codeLines: [String] = []
  var paragraphLines: [String] = []

  func flushParagraph() {
    guard !paragraphLines.isEmpty else { return }
    blocks.append(.paragraph(paragraphLines.joined(separator: "\n")))
    paragraphLines = []
  }

  for line in source.split(separator: "\n", omittingEmptySubsequences: false) {
    let s = String(line)
    let trimmed = s.trimmingCharacters(in: .whitespaces)
    if trimmed.hasPrefix("```") {
      if inCode {
        blocks.append(.code(language: codeLanguage, code: codeLines.joined(separator: "\n")))
        inCode = false
        codeLanguage = nil
        codeLines = []
      } else {
        flushParagraph()
        inCode = true
        let lang = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
        codeLanguage = lang.isEmpty ? nil : lang
      }
      continue
    }
    if inCode {
      codeLines.append(s)
      continue
    }
    if trimmed.isEmpty {
      flushParagraph()
      continue
    }
    if trimmed == "---" || trimmed == "***" || trimmed == "___" {
      flushParagraph()
      blocks.append(.rule)
      continue
    }
    var level = 0
    while level < trimmed.count && level < 6 && trimmed[trimmed.index(trimmed.startIndex, offsetBy: level)] == "#" {
      level += 1
    }
    if level > 0,
      trimmed.count > level,
      trimmed[trimmed.index(trimmed.startIndex, offsetBy: level)] == " "
    {
      flushParagraph()
      blocks.append(
        .heading(level: level, text: String(trimmed.dropFirst(level + 1))))
      continue
    }
    if trimmed.hasPrefix("> ") {
      flushParagraph()
      blocks.append(.quote(String(trimmed.dropFirst(2))))
      continue
    }
    if let item = markdownListItem(in: s) {
      flushParagraph()
      blocks.append(item)
      continue
    }
    paragraphLines.append(s)
  }
  flushParagraph()
  if inCode {
    blocks.append(.code(language: codeLanguage, code: codeLines.joined(separator: "\n")))
  }
  return blocks
}

private func markdownListItem(in line: String) -> MDBlock? {
  let indentation = line.prefix { $0 == " " }.count
  let trimmed = line.dropFirst(indentation)
  if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") {
    return .listItem(marker: "•", text: String(trimmed.dropFirst(2)), depth: indentation / 2)
  }

  let digits = trimmed.prefix { $0.isNumber }
  guard !digits.isEmpty else { return nil }
  let suffix = trimmed.dropFirst(digits.count)
  guard suffix.hasPrefix(". ") || suffix.hasPrefix(") ") else { return nil }
  return .listItem(
    marker: "\(digits).", text: String(suffix.dropFirst(2)), depth: indentation / 2)
}

struct MDRun: Equatable {
  var text: String
  var code: Bool = false
  var bold: Bool = false
}

func inlineRuns(_ text: String) -> [MDRun] {
  var runs: [MDRun] = []

  func appendBoldAware(_ text: Substring, code: Bool) {
    var rest = text
    while let open = rest.range(of: "**") {
      let plain = rest[..<open.lowerBound]
      if !plain.isEmpty { runs.append(MDRun(text: String(plain), code: code)) }
      let after = rest[open.upperBound...]
      guard let close = after.range(of: "**") else {
        runs.append(MDRun(text: String(rest[open.lowerBound...]), code: code))
        return
      }
      runs.append(MDRun(text: String(after[..<close.lowerBound]), code: code, bold: true))
      rest = after[close.upperBound...]
    }
    if !rest.isEmpty { runs.append(MDRun(text: String(rest), code: code)) }
  }

  var rest = Substring(text)
  while let tick = rest.firstIndex(of: "`") {
    appendBoldAware(rest[..<tick], code: false)
    let after = rest.index(after: tick)
    guard let close = rest[after...].firstIndex(of: "`") else {
      appendBoldAware(rest[tick...], code: false)
      return runs
    }
    runs.append(MDRun(text: String(rest[after..<close]), code: true))
    rest = rest[rest.index(after: close)...]
  }
  appendBoldAware(rest, code: false)
  return runs
}

enum VisualLineKind: Equatable {
  case plain
  case heading
  case code
}

struct VisualRun: Equatable {
  var text: String
  var color: Color
}

struct VisualLine: Equatable {
  var kind: VisualLineKind = .plain
  var runs: [VisualRun] = []
  var columnCount: Int = 0
  var trailingText: String = "\n"
}

func layoutMarkdown(
  _ blocks: [MDBlock],
  columns: Int,
  theme: MacTheme,
  baseColor: Color
) -> [VisualLine] {
  let columns = max(8, columns)
  var lines: [VisualLine] = []

  func wrapRuns(_ runs: [MDRun], colorFor: (MDRun) -> Color, kind: VisualLineKind) {
    var line = VisualLine(kind: kind)
    func emit(trailingText: String = "") {
      line.trailingText = trailingText
      lines.append(line)
      line = VisualLine(kind: kind)
    }
    for run in runs {
      let color = colorFor(run)
      var word = ""
      func flushWord() {
        guard !word.isEmpty else { return }
        var remaining = word
        word = ""
        while !remaining.isEmpty {
          if line.columnCount + remaining.count <= columns {
            line.runs.append(VisualRun(text: remaining, color: color))
            line.columnCount += remaining.count
            remaining = ""
          } else if remaining.count > columns {
            let room = columns - line.columnCount
            if room > 0 {
              let cut = remaining.index(remaining.startIndex, offsetBy: room)
              line.runs.append(VisualRun(text: String(remaining[..<cut]), color: color))
              line.columnCount += room
              remaining = String(remaining[cut...])
            }
            emit()
          } else {
            emit()
          }
        }
      }
      for ch in run.text {
        if ch == "\n" {
          flushWord()
          emit(trailingText: "\n")
        } else if ch == " " {
          flushWord()
          if line.columnCount >= columns { emit(trailingText: " ") }
          if line.columnCount > 0 {
            line.runs.append(VisualRun(text: " ", color: color))
            line.columnCount += 1
          }
        } else {
          word.append(ch)
        }
      }
      flushWord()
    }
    if line.columnCount > 0 || lines.isEmpty { emit() }
  }

  var previousWasListItem = false
  for (index, block) in blocks.enumerated() {
    let isListItem: Bool
    if case .listItem = block { isListItem = true } else { isListItem = false }
    if index > 0 {
      if !lines.isEmpty { lines[lines.count - 1].trailingText = "\n" }
      if !(isListItem && previousWasListItem) {
        lines.append(VisualLine(trailingText: "\n"))
      }
    }

    switch block {
    case .paragraph(let text):
      wrapRuns(
        inlineRuns(text),
        colorFor: { run in
          run.code ? theme.inlineCodeText : run.bold ? .white : baseColor
        }, kind: .plain)
    case .heading(let level, let text):
      let prefix = String(repeating: "#", count: level) + " "
      wrapRuns(
        [MDRun(text: prefix), MDRun(text: text, bold: true)],
        colorFor: { run in run.bold ? theme.accent : theme.green }, kind: .heading)
    case .listItem(let marker, let text, let depth):
      let indentation = String(repeating: "  ", count: min(depth, 4))
      var runs = [MDRun(text: indentation + marker + " ")]
      runs.append(contentsOf: inlineRuns(text))
      wrapRuns(
        runs,
        colorFor: { run in
          if run.text == indentation + marker + " " { return theme.orange }
          return run.code ? theme.inlineCodeText : run.bold ? .white : baseColor
        }, kind: .plain)
    case .quote(let text):
      var runs = [MDRun(text: "| ")]
      runs.append(contentsOf: inlineRuns(text))
      wrapRuns(
        runs,
        colorFor: { run in
          run.text == "| " ? theme.green : run.code ? theme.inlineCodeText : run.bold ? .white : baseColor
        }, kind: .plain)
    case .code(_, let code):
      let codeLines = code.split(separator: "\n", omittingEmptySubsequences: false)
      if codeLines.isEmpty {
        lines.append(VisualLine(kind: .code, runs: [VisualRun(text: "", color: theme.codeText)]))
      }
      for rawLine in codeLines {
        var rest = String(rawLine)
        if rest.isEmpty {
          lines.append(VisualLine(kind: .code, runs: [VisualRun(text: "", color: theme.codeText)]))
        }
        while !rest.isEmpty {
          let take = min(columns, rest.count)
          let cut = rest.index(rest.startIndex, offsetBy: take)
          let remainder = String(rest[cut...])
          lines.append(
            VisualLine(
              kind: .code,
              runs: [VisualRun(text: String(rest[..<cut]), color: theme.codeText)],
              columnCount: take,
              trailingText: remainder.isEmpty ? "\n" : ""))
          rest = remainder
        }
      }
    case .rule:
      lines.append(
        VisualLine(
          kind: .plain,
          runs: [VisualRun(text: String(repeating: "─", count: min(columns, 40)), color: theme.green)],
          columnCount: min(columns, 40)))
    }
    previousWasListItem = isListItem
  }
  while lines.last?.columnCount == 0 { lines.removeLast() }
  return lines
}

@MainActor
enum TranscriptViewportRegistry {
  static var current: Rect?
  static var lastDrawn: Rect?
  static var scrollController: ScrollViewController?
}

func selectionAutoscrollTarget(pointer: Point, viewport: Rect, step: Float = 18) -> Rect? {
  guard step > 0, step.isFinite else { return nil }
  if pointer.y < viewport.minY {
    return Rect(x: pointer.x, y: viewport.minY - step, width: 1, height: 1)
  }
  if pointer.y > viewport.maxY {
    return Rect(x: pointer.x, y: viewport.maxY + step, width: 1, height: 1)
  }
  return nil
}

@MainActor
enum TranscriptSelectionDocumentRegistry {
  struct Entry {
    let id: String
    let linesForColumns: (Int) -> [VisualLine]

    func layout(columns: Int, matching template: MarkdownLayout) -> MarkdownLayout {
      MarkdownLayout(
        lines: linesForColumns(max(1, columns)),
        lineHeight: template.lineHeight,
        cellWidth: template.cellWidth,
        scale: template.scale)
    }
  }

  private(set) static var entries: [Entry] = []
  private static var ownerID: UUID?

  static func setEntries(ownerID: UUID, _ entries: [Entry]) {
    let entryIDs = Set(entries.map(\.id))
    if self.ownerID != ownerID
      || !SelectionManager.shared.selectionEndpointsAreContained(in: entryIDs)
    {
      SelectionManager.shared.clear()
    }
    self.ownerID = ownerID
    self.entries = entries
  }

  static func entry(for id: String) -> Entry? {
    entries.first { $0.id == id }
  }
}

struct MarkdownLayout {
  var lines: [VisualLine]
  var lineHeight: Float
  var cellWidth: Float
  var scale: Float
  var rect: Rect = .zero

  func hitTest(point: Point) -> (line: Int, column: Int)? {
    guard rect.contains(point), lineHeight > 0, lineHeight.isFinite,
      cellWidth > 0, cellWidth.isFinite
    else { return nil }
    let lineIndex = Int((point.y - rect.minY) / lineHeight)
    guard lineIndex >= 0, lineIndex < lines.count else { return nil }
    let line = lines[lineIndex]
    let xOffset = point.x - rect.minX
    var col = 0
    var runX: Float = 0
    for run in line.runs {
      let runWidth = Float(run.text.count) * cellWidth
      if xOffset < runX + runWidth {
        col += Int(((xOffset - runX) / cellWidth).rounded(.toNearestOrAwayFromZero))
        return (lineIndex, max(0, min(col, line.columnCount)))
      }
      runX += runWidth
      col += run.text.count
    }
    return (lineIndex, line.columnCount)
  }

  func glyphOffset(at position: (line: Int, column: Int)) -> Int {
    guard !lines.isEmpty else { return 0 }
    let line = max(0, min(position.line, lines.count - 1))
    let preceding = lines[..<line].reduce(0) {
      $0 + $1.columnCount + $1.trailingText.count
    }
    return preceding + max(0, min(position.column, lines[line].columnCount))
  }

  func position(atGlyphOffset offset: Int) -> (line: Int, column: Int) {
    guard !lines.isEmpty else { return (0, 0) }
    var remaining = max(0, min(offset, glyphCount))
    for (index, line) in lines.enumerated() {
      let isLast = index == lines.count - 1
      if remaining < line.columnCount || isLast {
        return (index, min(remaining, line.columnCount))
      }
      if remaining == line.columnCount {
        if line.trailingText.isEmpty { return (index + 1, 0) }
        return (index, line.columnCount)
      }
      remaining -= line.columnCount
      if remaining < line.trailingText.count {
        return (index, line.columnCount)
      }
      remaining -= line.trailingText.count
    }
    return (lines.count - 1, lines.last?.columnCount ?? 0)
  }

  var glyphCount: Int {
    guard !lines.isEmpty else { return 0 }
    return lines.enumerated().reduce(0) { result, entry in
      result + entry.element.columnCount
        + (entry.offset < lines.count - 1 ? entry.element.trailingText.count : 0)
    }
  }

  func textInRange(from start: (line: Int, column: Int), to end: (line: Int, column: Int)) -> String {
    guard !lines.isEmpty else { return "" }
    let sl = max(0, min(start.line, lines.count - 1))
    let el = max(0, min(end.line, lines.count - 1))
    if sl > el || (sl == el && start.column >= end.column) { return "" }

    var result = ""
    for li in sl...el {
      let line = lines[li]
      let sc = (li == sl) ? max(0, min(start.column, line.columnCount)) : 0
      let ec = (li == el) ? max(0, min(end.column, line.columnCount)) : line.columnCount
      if sc < ec {
        var col = 0
        for run in line.runs {
          let runEnd = col + run.text.count
          if runEnd <= sc {
            col = runEnd
            continue
          }
          if col >= ec { break }
          let rs = max(0, sc - col)
          let re = min(run.text.count, ec - col)
          if rs < re {
            let startIdx = run.text.index(run.text.startIndex, offsetBy: rs)
            let endIdx = run.text.index(run.text.startIndex, offsetBy: re)
            result += run.text[startIdx..<endIdx]
          }
          col = runEnd
        }
      }
      if li < el { result += line.trailingText }
    }
    return result
  }

  func draw(
    into drawList: inout DrawList,
    selection: (start: (line: Int, column: Int), end: (line: Int, column: Int))?,
    theme: MacTheme,
    visibleRect: Rect?
  ) {
    let sel: (start: (line: Int, column: Int), end: (line: Int, column: Int))?
    if let selection {
      if selection.start.line < selection.end.line
        || (selection.start.line == selection.end.line
          && selection.start.column <= selection.end.column)
      {
        sel = selection
      } else {
        sel = (selection.end, selection.start)
      }
    } else {
      sel = nil
    }
    let visibleRange: Range<Int>
    if let visibleRect {
      let first = max(0, Int(floor((visibleRect.minY - rect.minY) / lineHeight)))
      let last = min(lines.count, Int(ceil((visibleRect.maxY - rect.minY) / lineHeight)))
      guard first < last else { return }
      visibleRange = first..<last
    } else {
      visibleRange = lines.indices
    }

    for index in visibleRange {
      let line = lines[index]
      let y = rect.minY + Float(index) * lineHeight
      if case .code = line.kind {
        drawList.fillRect(
          Rect(x: rect.minX, y: y, width: rect.size.width, height: lineHeight),
          color: theme.codeBackground)
      }
      if let sel {
        let sl = sel.start.line
        let el = sel.end.line
        if index >= sl && index <= el {
          let sc = (index == sl) ? sel.start.column : 0
          let ec = (index == el) ? sel.end.column : line.columnCount
          if sc < ec {
            let selX = rect.minX + Float(sc) * cellWidth
            let selW = Float(ec - sc) * cellWidth
            drawList.fillRect(
              Rect(x: selX, y: y, width: selW, height: lineHeight),
              color: theme.accent)
          }
        }
      }
      var x = rect.minX
      var column = 0
      for run in line.runs {
        let runEnd = column + run.text.count
        let selectedColumns: Range<Int>?
        if let sel, index >= sel.start.line, index <= sel.end.line {
          let selectionStart = (index == sel.start.line) ? sel.start.column : 0
          let selectionEnd = (index == sel.end.line) ? sel.end.column : line.columnCount
          let overlapStart = max(column, selectionStart)
          let overlapEnd = min(runEnd, selectionEnd)
          selectedColumns = overlapStart < overlapEnd ? overlapStart..<overlapEnd : nil
        } else {
          selectedColumns = nil
        }

        if let selectedColumns {
          let selectedStart = selectedColumns.lowerBound - column
          let selectedEnd = selectedColumns.upperBound - column
          let firstIndex = run.text.index(run.text.startIndex, offsetBy: selectedStart)
          let secondIndex = run.text.index(run.text.startIndex, offsetBy: selectedEnd)
          let prefix = String(run.text[..<firstIndex])
          let selectedText = String(run.text[firstIndex..<secondIndex])
          let suffix = String(run.text[secondIndex...])
          if !prefix.isEmpty {
            drawList.text(prefix, at: Point(x: x, y: y), color: run.color, scale: scale)
          }
          let selectedX = x + Float(selectedStart) * cellWidth
          drawList.text(
            selectedText, at: Point(x: selectedX, y: y), color: theme.background, scale: scale)
          if !suffix.isEmpty {
            let suffixX = x + Float(selectedEnd) * cellWidth
            drawList.text(suffix, at: Point(x: suffixX, y: y), color: run.color, scale: scale)
          }
        } else {
          drawList.text(run.text, at: Point(x: x, y: y), color: run.color, scale: scale)
        }
        x += Float(run.text.count) * cellWidth
        column = runEnd
      }
    }
  }
}

@MainActor
enum MarkdownLayoutRegistry {
  private static var layouts: [String: MarkdownLayout] = [:]

  static func register(_ id: String, layout: MarkdownLayout) {
    layouts[id] = layout
  }

  static func layout(for id: String) -> MarkdownLayout? {
    layouts[id]
  }

  static func entry(at point: Point) -> (id: String, layout: MarkdownLayout)? {
    for (id, layout) in layouts where !layout.lines.isEmpty && layout.rect.contains(point) {
      return (id, layout)
    }
    return nil
  }

  static func orderedEntries() -> [(id: String, layout: MarkdownLayout)] {
    layouts.compactMap { id, layout in
      layout.lines.isEmpty ? nil : (id: id, layout: layout)
    }.sorted {
      if $0.layout.rect.minY == $1.layout.rect.minY {
        return $0.layout.rect.minX < $1.layout.rect.minX
      }
      return $0.layout.rect.minY < $1.layout.rect.minY
    }
  }

  static func clear() {
    layouts.removeAll()
  }
}

struct MarkdownText: PrimitiveBlock {
  var markdown: String
  var theme: MacTheme
  var baseColor: Color
  var scale: Float = 0.5
  var lineSpacing: Float = 4
  var isPlainText = false
  var itemID: String? = nil

  func lines(forWidth width: Float, metrics: FontMetrics) -> [VisualLine] {
    let columns = Int(width / (metrics.cellAdvance * scale))
    if isPlainText {
      return layoutPlainText(markdown, columns: columns, color: baseColor)
    }
    return layoutMarkdown(
      segmentMarkdown(markdown),
      columns: columns,
      theme: theme,
      baseColor: baseColor)
  }

  @MainActor func sizeThatFits(_ proposal: Size, context: RenderContext) -> Size {
    let metrics = context.fontMetrics
    let lineHeight = metrics.lineAdvance * scale + lineSpacing
    let laidOut = lines(forWidth: proposal.width, metrics: metrics)
    return Size(width: proposal.width, height: max(1, Float(laidOut.count)) * lineHeight)
  }

  @MainActor func draw(into drawList: inout DrawList, in rect: Rect, context: RenderContext) {
    let metrics = context.fontMetrics
    let cellWidth = metrics.cellAdvance * scale
    let lineHeight = metrics.lineAdvance * scale + lineSpacing
    let laidOut = lines(forWidth: rect.size.width, metrics: metrics)
    let layout = MarkdownLayout(
      lines: laidOut, lineHeight: lineHeight, cellWidth: cellWidth,
      scale: scale, rect: rect)
    if let id = itemID {
      MarkdownLayoutRegistry.register(id, layout: layout)
    }
    let visibleRect = TranscriptViewportRegistry.current
    let selection = itemID.flatMap { SelectionManager.shared.selection(for: $0, layout: layout) }
    layout.draw(
      into: &drawList, selection: selection, theme: theme,
      visibleRect: visibleRect)
  }
}

struct WrappedText: Block {
  var text: String
  var theme: MacTheme
  var color: Color
  var scale: Float = 0.5
  var itemID: String? = nil

  var body: MarkdownText {
    MarkdownText(
      markdown: text, theme: theme, baseColor: color, scale: scale,
      isPlainText: true, itemID: itemID)
  }
}

func shouldProcessSelectionDrag(
  isDragging: Bool,
  pointerReleased: Bool,
  hasDragOrigin: Bool
) -> Bool {
  isDragging || (pointerReleased && hasDragOrigin)
}

@MainActor
final class SelectionManager {
  static let shared = SelectionManager()

  private var originLayoutID: String? = nil
  private var endLayoutID: String? = nil
  private var retainedSelectionEntries: [(id: String, layout: MarkdownLayout)]? = nil
  private(set) var selectionStart: (line: Int, column: Int)?
  private(set) var selectionEnd: (line: Int, column: Int)?
  private var selectionStartGlyphOffset: Int?
  private var selectionEndGlyphOffset: Int?
  var isSelecting: Bool = false

  private init() {}

  func updateFromDrag(context: RenderContext) {
    let isReleaseFrame = context.input.pointerReleased && context.pointerDragOrigin != nil
    guard
      shouldProcessSelectionDrag(
        isDragging: context.isPointerDragging,
        pointerReleased: context.input.pointerReleased,
        hasDragOrigin: context.pointerDragOrigin != nil),
      let origin = context.pointerDragOrigin
    else {
      return
    }
    defer {
      if isReleaseFrame, isSelecting {
        retainCurrentSelection()
        isSelecting = false
      }
    }

    if !isSelecting {
      isSelecting = true
      originLayoutID = nil
      endLayoutID = nil
      retainedSelectionEntries = nil
      selectionStart = nil
      selectionEnd = nil
      selectionStartGlyphOffset = nil
      selectionEndGlyphOffset = nil
    }

    let current = context.pointerDragPosition
    let visibleEntries = MarkdownLayoutRegistry.orderedEntries()

    if context.isPointerDragging, originLayoutID != nil,
      let viewport = TranscriptViewportRegistry.lastDrawn,
      let target = selectionAutoscrollTarget(pointer: current, viewport: viewport)
    {
      TranscriptViewportRegistry.scrollController?.scrollToVisible(target)
      context.requestRedraw()
    }

    if originLayoutID == nil {
      if let entry = MarkdownLayoutRegistry.entry(at: origin),
        let hit = entry.layout.hitTest(point: origin)
      {
        context.endEditing()
        originLayoutID = entry.id
        endLayoutID = entry.id
        selectionStart = hit
        selectionEnd = hit
        selectionStartGlyphOffset = entry.layout.glyphOffset(at: hit)
        selectionEndGlyphOffset = selectionStartGlyphOffset
        retainedSelectionEntries = visibleEntries
      }
    }

    guard originLayoutID != nil, selectionStart != nil else { return }

    mergeSelectionEntries(
      visibleEntries, appendIfDisjoint: current.y >= origin.y)

    if let entry = MarkdownLayoutRegistry.entry(at: current),
      let endHit = entry.layout.hitTest(point: current)
    {
      endLayoutID = entry.id
      selectionEnd = endHit
      selectionEndGlyphOffset = entry.layout.glyphOffset(at: endHit)
      return
    }

    let entries = visibleEntries
    guard !entries.isEmpty else { return }
    let entry: (id: String, layout: MarkdownLayout)
    if current.y < entries[0].layout.rect.minY {
      entry = entries[0]
      endLayoutID = entry.id
      selectionEnd = (0, 0)
      selectionEndGlyphOffset = 0
      return
    } else if current.y > entries[entries.count - 1].layout.rect.maxY {
      entry = entries[entries.count - 1]
      endLayoutID = entry.id
      selectionEnd = lastPosition(in: entry.layout)
      selectionEndGlyphOffset = entry.layout.glyphCount
      return
    } else {
      entry =
        entries.min {
          verticalDistance(from: current.y, to: $0.layout.rect)
            < verticalDistance(from: current.y, to: $1.layout.rect)
        } ?? entries[0]
    }

    endLayoutID = entry.id
    let layout = entry.layout
    let line = max(
      0, min(layout.lines.count - 1, Int((current.y - layout.rect.minY) / layout.lineHeight)))
    if current.y <= layout.rect.minY {
      selectionEnd = (0, 0)
    } else if current.y >= layout.rect.maxY {
      selectionEnd = lastPosition(in: layout)
    } else if current.x >= layout.rect.maxX {
      selectionEnd = (line, layout.lines[line].columnCount)
    } else {
      selectionEnd = (line, 0)
    }
    selectionEndGlyphOffset = selectionEnd.map { layout.glyphOffset(at: $0) }
  }

  func selection(
    for id: String,
    layout: MarkdownLayout
  ) -> (start: (line: Int, column: Int), end: (line: Int, column: Int))? {
    guard let originID = originLayoutID, let endID = endLayoutID,
      let selectionStart, let selectionEnd
    else { return nil }
    let resolvedStart =
      id == originID
      ? layout.position(atGlyphOffset: selectionStartGlyphOffset ?? layout.glyphOffset(at: selectionStart))
      : selectionStart
    let resolvedEnd =
      id == endID
      ? layout.position(atGlyphOffset: selectionEndGlyphOffset ?? layout.glyphOffset(at: selectionEnd))
      : selectionEnd

    let document = TranscriptSelectionDocumentRegistry.entries
    if let index = document.firstIndex(where: { $0.id == id }),
      let originIndex = document.firstIndex(where: { $0.id == originID }),
      let endIndex = document.firstIndex(where: { $0.id == endID }),
      index >= min(originIndex, endIndex), index <= max(originIndex, endIndex)
    {
      if originIndex < endIndex {
        let start = index == originIndex ? resolvedStart : (0, 0)
        let end = index == endIndex ? resolvedEnd : lastPosition(in: layout)
        return (start, end)
      }
      if originIndex > endIndex {
        let start = index == endIndex ? resolvedEnd : (0, 0)
        let end = index == originIndex ? resolvedStart : lastPosition(in: layout)
        return (start, end)
      }
      return precedes(resolvedStart, resolvedEnd)
        ? (resolvedStart, resolvedEnd)
        : (resolvedEnd, resolvedStart)
    }

    guard let range = orderedSelection(),
      let index = range.entries.firstIndex(where: { $0.id == id }),
      index >= range.startIndex, index <= range.endIndex
    else { return nil }
    let start = index == range.startIndex ? range.start : (0, 0)
    let end = index == range.endIndex ? range.end : lastPosition(in: layout)
    return (start, end)
  }

  func selectionEndpointsAreContained(in entryIDs: Set<String>) -> Bool {
    guard let originLayoutID, let endLayoutID else { return true }
    return entryIDs.contains(originLayoutID) && entryIDs.contains(endLayoutID)
  }

  func selectAll(isTranscriptVisible: Bool) -> Bool {
    guard isTranscriptVisible else { return false }
    let document = TranscriptSelectionDocumentRegistry.entries
    let documentIDs = Set(document.map(\.id))
    let anchor: (id: String, layout: MarkdownLayout)?
    if let layoutID = originLayoutID, let layout = MarkdownLayoutRegistry.layout(for: layoutID) {
      anchor = (layoutID, layout)
    } else if let pointed = MarkdownLayoutRegistry.entry(
      at: ScribeRenderContext.current?.input.pointerPosition ?? .zero)
    {
      anchor = pointed
    } else {
      anchor = MarkdownLayoutRegistry.orderedEntries().first {
        documentIDs.contains($0.id)
      }
    }
    guard let anchor, !anchor.layout.lines.isEmpty else { return false }

    if document.contains(where: { $0.id == anchor.id }), !document.isEmpty {
      let columns = max(
        1, Int((anchor.layout.rect.size.width / anchor.layout.cellWidth).rounded(.down)))
      let entries = document.map { entry in
        let layout =
          MarkdownLayoutRegistry.layout(for: entry.id)
          ?? entry.layout(columns: columns, matching: anchor.layout)
        return (id: entry.id, layout: layout)
      }
      guard let first = entries.first, let last = entries.last else { return false }
      originLayoutID = first.id
      endLayoutID = last.id
      retainedSelectionEntries = entries
      selectionStart = (0, 0)
      selectionEnd = lastPosition(in: last.layout)
      selectionStartGlyphOffset = 0
      selectionEndGlyphOffset = last.layout.glyphCount
    } else {
      originLayoutID = anchor.id
      endLayoutID = anchor.id
      retainedSelectionEntries = [anchor]
      selectionStart = (0, 0)
      selectionEnd = lastPosition(in: anchor.layout)
      selectionStartGlyphOffset = 0
      selectionEndGlyphOffset = anchor.layout.glyphCount
    }
    isSelecting = false
    return true
  }

  func copyText(isTranscriptVisible: Bool) -> String? {
    guard isTranscriptVisible else { return nil }
    return selectedText()
  }

  func selectedText() -> String? {
    guard let range = orderedSelection() else { return nil }
    var parts: [String] = []
    for index in range.startIndex...range.endIndex {
      let entry = range.entries[index]
      let start = index == range.startIndex ? range.start : (0, 0)
      let end = index == range.endIndex ? range.end : lastPosition(in: entry.layout)
      parts.append(entry.layout.textInRange(from: start, to: end))
    }
    return parts.joined(separator: "\n")
  }

  private typealias Position = (line: Int, column: Int)

  private func orderedSelection() -> (
    entries: [(id: String, layout: MarkdownLayout)],
    startIndex: Int, endIndex: Int, start: Position, end: Position
  )? {
    guard let originID = originLayoutID, let endID = endLayoutID,
      let selectionStart, let selectionEnd
    else { return nil }
    if let documentRange = documentSelectionEntries(originID: originID, endID: endID) {
      let firstLayout = documentRange.entries[0].layout
      let lastLayout = documentRange.entries[documentRange.entries.count - 1].layout
      if documentRange.originPrecedesEnd {
        let start = firstLayout.position(
          atGlyphOffset: selectionStartGlyphOffset ?? firstLayout.glyphOffset(at: selectionStart))
        let end = lastLayout.position(
          atGlyphOffset: selectionEndGlyphOffset ?? lastLayout.glyphOffset(at: selectionEnd))
        return (documentRange.entries, 0, documentRange.entries.count - 1, start, end)
      }
      if documentRange.entries.count > 1 {
        let start = firstLayout.position(
          atGlyphOffset: selectionEndGlyphOffset ?? firstLayout.glyphOffset(at: selectionEnd))
        let end = lastLayout.position(
          atGlyphOffset: selectionStartGlyphOffset ?? lastLayout.glyphOffset(at: selectionStart))
        return (documentRange.entries, 0, documentRange.entries.count - 1, start, end)
      }
      let start = firstLayout.position(
        atGlyphOffset: selectionStartGlyphOffset ?? firstLayout.glyphOffset(at: selectionStart))
      let end = firstLayout.position(
        atGlyphOffset: selectionEndGlyphOffset ?? firstLayout.glyphOffset(at: selectionEnd))
      if precedes(start, end) {
        return (documentRange.entries, 0, 0, start, end)
      }
      return (documentRange.entries, 0, 0, end, start)
    }

    let entries = retainedSelectionEntries ?? MarkdownLayoutRegistry.orderedEntries()
    guard let originIndex = entries.firstIndex(where: { $0.id == originID }),
      let endIndex = entries.firstIndex(where: { $0.id == endID })
    else { return nil }

    if originIndex < endIndex {
      return (entries, originIndex, endIndex, selectionStart, selectionEnd)
    }
    if originIndex > endIndex {
      return (entries, endIndex, originIndex, selectionEnd, selectionStart)
    }
    if precedes(selectionStart, selectionEnd) {
      return (entries, originIndex, endIndex, selectionStart, selectionEnd)
    }
    return (entries, originIndex, endIndex, selectionEnd, selectionStart)
  }

  private func documentSelectionEntries(
    originID: String,
    endID: String
  ) -> (entries: [(id: String, layout: MarkdownLayout)], originPrecedesEnd: Bool)? {
    let document = TranscriptSelectionDocumentRegistry.entries
    guard let originIndex = document.firstIndex(where: { $0.id == originID }),
      let endIndex = document.firstIndex(where: { $0.id == endID }),
      let originLayout = MarkdownLayoutRegistry.layout(for: originID)
        ?? retainedSelectionEntries?.first(where: { $0.id == originID })?.layout,
      let endLayout = MarkdownLayoutRegistry.layout(for: endID)
        ?? retainedSelectionEntries?.first(where: { $0.id == endID })?.layout
    else { return nil }

    let lower = min(originIndex, endIndex)
    let upper = max(originIndex, endIndex)
    let template = originLayout
    let columns = max(1, Int((template.rect.size.width / template.cellWidth).rounded(.down)))
    let entries = document[lower...upper].map { entry in
      if entry.id == originID { return (id: entry.id, layout: originLayout) }
      if entry.id == endID { return (id: entry.id, layout: endLayout) }
      return (id: entry.id, layout: entry.layout(columns: columns, matching: template))
    }
    return (entries, originIndex < endIndex)
  }

  private func retainCurrentSelection() {
    guard let originID = originLayoutID, let endID = endLayoutID else { return }
    mergeSelectionEntries(MarkdownLayoutRegistry.orderedEntries(), appendIfDisjoint: true)
    guard let entries = retainedSelectionEntries,
      let originIndex = entries.firstIndex(where: { $0.id == originID }),
      let endIndex = entries.firstIndex(where: { $0.id == endID })
    else { return }
    retainedSelectionEntries = Array(entries[min(originIndex, endIndex)...max(originIndex, endIndex)])
  }

  private func mergeSelectionEntries(
    _ visible: [(id: String, layout: MarkdownLayout)],
    appendIfDisjoint: Bool
  ) {
    guard !visible.isEmpty else { return }
    guard var retained = retainedSelectionEntries else {
      retainedSelectionEntries = visible
      return
    }

    for entry in visible {
      if let index = retained.firstIndex(where: { $0.id == entry.id }) {
        retained[index] = entry
      }
    }

    let hasOverlap = visible.contains { entry in
      retained.contains(where: { $0.id == entry.id })
    }
    if !hasOverlap {
      if appendIfDisjoint {
        retained.append(contentsOf: visible)
      } else {
        retained.insert(contentsOf: visible, at: 0)
      }
      retainedSelectionEntries = retained
      return
    }

    for (visibleIndex, entry) in visible.enumerated() {
      guard !retained.contains(where: { $0.id == entry.id }) else { continue }
      if visibleIndex > 0,
        let previous = retained.firstIndex(where: { $0.id == visible[visibleIndex - 1].id })
      {
        retained.insert(entry, at: previous + 1)
      } else if visibleIndex + 1 < visible.count,
        let next = retained.firstIndex(where: { $0.id == visible[visibleIndex + 1].id })
      {
        retained.insert(entry, at: next)
      } else if appendIfDisjoint {
        retained.append(entry)
      } else {
        retained.insert(entry, at: 0)
      }
    }
    retainedSelectionEntries = retained
  }

  private func precedes(_ lhs: Position, _ rhs: Position) -> Bool {
    lhs.line < rhs.line || (lhs.line == rhs.line && lhs.column <= rhs.column)
  }

  private func lastPosition(in layout: MarkdownLayout) -> Position {
    let lastLine = max(0, layout.lines.count - 1)
    return (lastLine, layout.lines.last?.columnCount ?? 0)
  }

  private func verticalDistance(from y: Float, to rect: Rect) -> Float {
    if y < rect.minY { return rect.minY - y }
    if y > rect.maxY { return y - rect.maxY }
    return 0
  }

  func clear() {
    originLayoutID = nil
    endLayoutID = nil
    retainedSelectionEntries = nil
    selectionStart = nil
    selectionEnd = nil
    selectionStartGlyphOffset = nil
    selectionEndGlyphOffset = nil
    isSelecting = false
  }
}
