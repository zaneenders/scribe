import Chroma
import Foundation

// MARK: - ASCII sanitization

/// Scribe's editable and generated prose is restricted to printable ASCII so
/// caret math and text interchange remain predictable. Chroma may also contain
/// a small set of UI glyphs, but those are used only by fixed interface labels.
/// Transliterate usual LLM punctuation and map unsupported prose to `?`.
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
      if scalar.value >= 0x20 && scalar.value <= 0x7E {
        out.unicodeScalars.append(scalar)
      } else if scalar.properties.generalCategory != .nonspacingMark {
        out += "?"
      }
    }
  }
  return out
}

// MARK: - Block segmentation

enum MDBlock: Equatable {
  case paragraph(String)
  case code(language: String?, code: String)
  case heading(level: Int, text: String)
  case listItem(marker: String, text: String, depth: Int)
  case quote(String)
  case rule
}

/// Line-based markdown segmentation: fenced code blocks, ATX headings,
/// horizontal rules, and everything else as reflowed paragraphs. Tolerant of
/// unterminated fences so it can render mid-stream.
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

// MARK: - Inline runs

struct MDRun: Equatable {
  var text: String
  var code: Bool = false
  var bold: Bool = false
}

/// Splits paragraph text into runs at `code spans` and **bold** spans.
/// Unterminated markers render literally — streaming-safe.
func inlineRuns(_ text: String) -> [MDRun] {
  var runs: [MDRun] = []

  func appendBoldAware(_ text: Substring, code: Bool) {
    var rest = text
    while let open = rest.range(of: "**") {
      let plain = rest[..<open.lowerBound]
      if !plain.isEmpty { runs.append(MDRun(text: String(plain), code: code)) }
      let after = rest[open.upperBound...]
      guard let close = after.range(of: "**") else {
        runs.append(MDRun(text: String(rest), code: code))
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

// MARK: - Visual layout

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
}

/// Reflows markdown blocks into visual lines of colored runs for a column
/// budget. Chroma's only text styling is color, so emphasis maps: bold →
/// bright, inline code → amber, code blocks → green-on-dark, headings → blue.
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
    func emit() {
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
            // Long unbreakable word: hard-split across lines.
            let room = columns - line.columnCount
            if room > 0 {
              let cut = remaining.index(remaining.startIndex, offsetBy: room)
              line.runs.append(VisualRun(text: String(remaining[..<cut]), color: color))
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
          emit()
        } else if ch == " " {
          flushWord()
          if line.columnCount >= columns { emit() }
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
    if index > 0 && !(isListItem && previousWasListItem) {
      lines.append(VisualLine())
    }

    switch block {
    case .paragraph(let text):
      wrapRuns(inlineRuns(text), colorFor: { run in
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
      wrapRuns(runs, colorFor: { run in
        if run.text == indentation + marker + " " { return theme.orange }
        return run.code ? theme.inlineCodeText : run.bold ? .white : baseColor
      }, kind: .plain)
    case .quote(let text):
      var runs = [MDRun(text: "| ")]
      runs.append(contentsOf: inlineRuns(text))
      wrapRuns(runs, colorFor: { run in
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
          lines.append(
            VisualLine(
              kind: .code,
              runs: [VisualRun(text: String(rest[..<cut]), color: theme.codeText)],
              columnCount: take))
          rest = String(rest[cut...])
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

// MARK: - Blocks

/// The active transcript clip while LazyVStack draws its visible rows.
/// MarkdownText also uses it to cull lines inside an unusually tall row.
@MainActor
enum TranscriptViewportRegistry {
  static var current: Rect?
}

/// The computed layout of a MarkdownText block for one frame, cached for
/// hit testing and text extraction by the selection system.
struct MarkdownLayout {
  var lines: [VisualLine]
  var lineHeight: Float
  var cellWidth: Float
  var scale: Float
  /// The screen rect where this block was drawn (in the window's coordinate space).
  var rect: Rect = .zero

  /// Returns the (line index, column) for a point in window coordinates,
  /// or nil if the point is outside this block.
  func hitTest(point: Point) -> (line: Int, column: Int)? {
    guard rect.contains(point) else { return nil }
    let lineIndex = Int((point.y - rect.minY) / lineHeight)
    guard lineIndex >= 0, lineIndex < lines.count else { return nil }
    let line = lines[lineIndex]
    let xOffset = point.x - rect.minX
    var col = 0
    var runX: Float = 0
    for run in line.runs {
      let runWidth = Float(run.text.count) * cellWidth
      if xOffset < runX + runWidth {
        col += Int((xOffset - runX) / cellWidth)
        return (lineIndex, min(col, line.columnCount))
      }
      runX += runWidth
      col += run.text.count
    }
    return (lineIndex, line.columnCount)
  }

  /// Extracts the text in the given range (line, column) → (line, column).
  /// Ranges are clamped to valid bounds. The end is exclusive.
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
      // A range crossing a visual line boundary includes its newline, even
      // when either side lands exactly at a line edge or the line is empty.
      if li < el { result += "\n" }
    }
    return result
  }

  /// Draws only lines intersecting the transcript viewport. The full layout is
  /// retained for measurement and selection, but off-screen lines produce no
  /// draw commands.
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
        let sl = sel.start.line, el = sel.end.line
        if index >= sl && index <= el {
          let sc = (index == sl) ? sel.start.column : 0
          let ec = (index == el) ? sel.end.column : line.columnCount
          if sc < ec {
            // Draw selection background behind the selected text portion
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

/// A per-frame registry of MarkdownLayouts, populated during draw and
/// queried for hit testing during drag selection.
@MainActor
enum MarkdownLayoutRegistry {
  private static var layouts: [WidgetID: MarkdownLayout] = [:]

  static func register(_ id: WidgetID, layout: MarkdownLayout) {
    layouts[id] = layout
  }

  static func layout(for id: WidgetID) -> MarkdownLayout? {
    layouts[id]
  }

  /// Returns the layout whose rect contains the given point, or nil.
  static func layout(at point: Point) -> MarkdownLayout? {
    for (_, layout) in layouts {
      if layout.rect.contains(point) { return layout }
    }
    return nil
  }

  /// Returns the layout with the given rect, or nil.
  static func layout(withRect rect: Rect) -> MarkdownLayout? {
    for (_, layout) in layouts {
      if layout.rect == rect { return layout }
    }
    return nil
  }

  static func clear() {
    layouts.removeAll()
  }
}

/// A markdown source string rendered as wrapped, colored runs inside the
/// width the layout engine proposes.
struct MarkdownText: PrimitiveBlock {
  var markdown: String
  var theme: MacTheme
  var baseColor: Color
  var scale: Float = 0.5
  var lineSpacing: Float = 2
  /// Optional stable ID for this block, used to register its layout for
  /// hit testing and text selection.
  var itemID: WidgetID? = nil

  private func lines(forWidth width: Float, metrics: FontMetrics) -> [VisualLine] {
    let columns = Int(width / (metrics.cellAdvance * scale))
    return layoutMarkdown(
      segmentMarkdown(sanitizeASCII(markdown)),
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
    // LazyVStack already skips whole off-screen transcript rows. Limit this
    // potentially large row to the viewport as well, so a single long answer
    // does not emit draw commands for every markdown line.
    let visibleRect = TranscriptViewportRegistry.current
    let selection = SelectionManager.shared.selection(for: layout)
    layout.draw(
      into: &drawList, selection: selection, theme: theme,
      visibleRect: visibleRect)
  }
}

/// A one-line convenience wrapper for colored, wrapped plain text (notices,
/// tool output) — routed through the same layout as markdown.
struct WrappedText: Block {
  var text: String
  var theme: MacTheme
  var color: Color
  var scale: Float = 0.5
  /// Optional stable ID for this block, used to register its layout for
  /// hit testing and text selection.
  var itemID: WidgetID? = nil

  var body: MarkdownText {
    MarkdownText(markdown: text, theme: theme, baseColor: color, scale: scale, itemID: itemID)
  }
}

// MARK: - Selection Manager

/// Tracks text selection across frames. Reads drag state from Interaction
/// and maps it to text positions using the MarkdownLayoutRegistry.
@MainActor
final class SelectionManager {
  static let shared = SelectionManager()

  /// The rect of the layout where the selection originated.
  private var originLayoutRect: Rect? = nil
  private(set) var selectionStart: (line: Int, column: Int)?
  private(set) var selectionEnd: (line: Int, column: Int)?
  /// Whether a drag is in progress (selection is being extended).
  var isSelecting: Bool = false

  private init() {}

  /// Call at the start of each frame to update selection from drag state.
  func updateFromDrag(context: RenderContext) {
    let input = context.input
    guard input.pointerDown && input.pointerPosition != input.pointerPressPosition else {
      if isSelecting {
        isSelecting = false
      }
      return
    }

    if !isSelecting {
      isSelecting = true
      originLayoutRect = nil
      selectionStart = nil
      selectionEnd = nil
    }

    let origin = input.pointerPressPosition
    let current = input.pointerPosition

    if originLayoutRect == nil {
      // First drag frame — find the layout under the origin
      if let layout = MarkdownLayoutRegistry.layout(at: origin),
        let hit = layout.hitTest(point: origin)
      {
        originLayoutRect = layout.rect
        selectionStart = hit
      }
    }

    guard let layoutRect = originLayoutRect else { return }
    guard let layout = MarkdownLayoutRegistry.layout(withRect: layoutRect),
      selectionStart != nil else { return }

    if let endHit = layout.hitTest(point: current) {
      selectionEnd = endHit
    } else if current.y > layout.rect.maxY {
      selectionEnd = (layout.lines.count - 1, layout.lines.last?.columnCount ?? 0)
    } else if current.y < layout.rect.minY {
      selectionEnd = (0, 0)
    }
  }

  /// Returns the normalized selection range if it overlaps the given layout,
  /// or nil. Normalized means start <= end.
  func selection(for layout: MarkdownLayout) -> (start: (line: Int, column: Int), end: (line: Int, column: Int))? {
    guard let rect = originLayoutRect, rect == layout.rect else { return nil }
    guard let start = selectionStart, let end = selectionEnd else { return nil }
    if start.line < end.line || (start.line == end.line && start.column <= end.column) {
      return (start, end)
    }
    return (end, start)
  }

  /// Returns the currently selected text, or nil if nothing is selected.
  func selectedText() -> String? {
    guard let rect = originLayoutRect,
      let start = selectionStart,
      let end = selectionEnd else { return nil }

    guard let layout = MarkdownLayoutRegistry.layout(withRect: rect) else { return nil }

    let s: (line: Int, column: Int)
    let e: (line: Int, column: Int)
    if start.line < end.line || (start.line == end.line && start.column <= end.column) {
      s = start; e = end
    } else {
      s = end; e = start
    }
    return layout.textInRange(from: s, to: e)
  }

  /// Clears the selection.
  func clear() {
    originLayoutRect = nil
    selectionStart = nil
    selectionEnd = nil
    isSelecting = false
  }
}
