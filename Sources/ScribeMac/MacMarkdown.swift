import Chroma
import Foundation

// MARK: - ASCII sanitization

/// Chroma's bitmap font covers printable ASCII (0x20–0x7E) and the renderer
/// advances one cell per UTF-8 *byte*, so anything else breaks both display
/// and caret math. Transliterate the usual LLM punctuation to ASCII and map
/// everything else to `?` until Chroma grows a real font stack.
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
    paragraphLines.append(s)
  }
  flushParagraph()
  if inCode {
    blocks.append(.code(language: codeLanguage, code: codeLines.joined(separator: "\n")))
  }
  return blocks
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

  for block in blocks {
    switch block {
    case .paragraph(let text):
      wrapRuns(inlineRuns(text), colorFor: { run in
        run.code ? theme.inlineCodeText : run.bold ? .white : baseColor
      }, kind: .plain)
    case .heading(_, let text):
      wrapRuns([MDRun(text: text, bold: true)], colorFor: { _ in theme.accent }, kind: .heading)
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
          runs: [VisualRun(text: String(repeating: "-", count: min(columns, 40)), color: theme.border)],
          columnCount: min(columns, 40)))
    }
  }
  return lines
}

// MARK: - Blocks

/// A markdown source string rendered as wrapped, colored runs inside the
/// width the layout engine proposes.
struct MarkdownText: PrimitiveBlock {
  var markdown: String
  var theme: MacTheme
  var baseColor: Color
  var scale: Float = 2
  var lineSpacing: Float = 4

  private func lines(forWidth width: Float) -> [VisualLine] {
    let metrics = FontMetrics()
    let columns = Int(width / (metrics.cellAdvance * scale))
    return layoutMarkdown(
      segmentMarkdown(sanitizeASCII(markdown)),
      columns: columns,
      theme: theme,
      baseColor: baseColor)
  }

  @MainActor func sizeThatFits(_ proposal: Size) -> Size {
    let metrics = FontMetrics()
    let lineHeight = metrics.lineAdvance * scale + lineSpacing
    let laidOut = lines(forWidth: proposal.width)
    return Size(width: proposal.width, height: max(1, Float(laidOut.count)) * lineHeight)
  }

  @MainActor func draw(into drawList: inout DrawList, in rect: Rect) {
    let metrics = FontMetrics()
    let cellWidth = metrics.cellAdvance * scale
    let lineHeight = metrics.lineAdvance * scale + lineSpacing
    let laidOut = lines(forWidth: rect.size.width)
    for (index, line) in laidOut.enumerated() {
      let y = rect.minY + Float(index) * lineHeight
      if case .code = line.kind {
        drawList.fillRect(
          Rect(x: rect.minX, y: y, width: rect.size.width, height: lineHeight),
          color: theme.codeBackground)
      }
      var x = rect.minX
      for run in line.runs {
        drawList.text(run.text, at: Point(x: x, y: y), color: run.color, scale: scale)
        x += Float(run.text.count) * cellWidth
      }
    }
  }
}

/// A one-line convenience wrapper for colored, wrapped plain text (notices,
/// tool output) — routed through the same layout as markdown.
struct WrappedText: Block {
  var text: String
  var theme: MacTheme
  var color: Color
  var scale: Float = 2

  var body: MarkdownText {
    MarkdownText(markdown: text, theme: theme, baseColor: color, scale: scale)
  }
}
