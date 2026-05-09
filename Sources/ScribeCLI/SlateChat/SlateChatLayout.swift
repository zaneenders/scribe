import Foundation
import ScribeCore
import SlateCore

// MARK: - Styled transcript model

public struct StyledSpan: Equatable, Sendable, TerminalSpanProtocol {
  public var fg: TerminalRGB
  public var bg: TerminalRGB
  public var bold: Bool
  public var text: String

  // TerminalSpanProtocol conformance — bridges naming conventions.
  public var foreground: TerminalRGB { fg }
  public var background: TerminalRGB { bg }
  public var flags: TerminalCellFlags { bold ? .bold : [] }

  public init(fg: TerminalRGB, bg: TerminalRGB, bold: Bool, text: String) {
    self.fg = fg
    self.bg = bg
    self.bold = bold
    self.text = text
  }
}

public struct TLine: Equatable, Sendable {
  public var spans: [StyledSpan]

  public init(spans: [StyledSpan]) {
    self.spans = spans
  }
}

// MARK: - Snapshot types

/// Snapshot of token-usage counters rendered in the upper‑right HUD strip.
///
/// Two scopes are tracked:
/// - **Round** – the single most recent API response (one HTTP request/response pair).
/// - **Turn** – the sum of every API round triggered by the current user message
///   (including tool‑call loops). Reset to zero when a new user turn starts
///   (`.modelTurnRunning(true)`).
/// - **Session** – the cumulative total across all turns since `scribe chat` began.
///   Never reset during a session.
internal struct UsageHUDSnapshot: Equatable {
  /// Prompt tokens in the most recent API round.
  var roundPrompt: Int?
  /// Completion tokens in the most recent API round.
  var roundCompletion: Int?
  /// Total tokens in the most recent API round.
  var roundTotal: Int?
  /// Prompt tokens summed across all API rounds in the current user turn.
  var turnPrompt: Int
  /// Completion tokens summed across all API rounds in the current user turn.
  var turnCompletion: Int
  /// Total tokens summed across all API rounds in the current user turn.
  var turnTotal: Int
  /// Prompt tokens summed across every turn in the current chat session.
  var sessionPrompt: Int
  /// Completion tokens summed across every turn in the current chat session.
  var sessionCompletion: Int
  /// Total tokens summed across every turn in the current chat session.
  var sessionTotal: Int
  var reasoningTokens: Int?
  var cachedPromptTokens: Int?
  var outputTokensPerSecond: Double?
  var contextWindow: Int?
  var contextWindowUsedPercent: Int?
}

internal struct BannerSnapshot: Equatable {
  var baseURL: String
  var model: String
  var cwd: String
  var scribeVersion: String
  var gitBranch: String?
  var sessionId: String
}

// MARK: - Layout

internal enum TranscriptLayout {

  private static func wrappedPlainLines(_ text: String, width: Int) -> [String] {
    guard width > 0 else { return [] }
    if text.isEmpty { return [""] }

    // Tokenize into Substring ranges (no per-token String allocation).
    var tokenRanges: [Range<String.Index>] = []
    var i = text.startIndex
    while i < text.endIndex {
      var j = i
      if text[i] == " " {
        while j < text.endIndex && text[j] == " " { j = text.index(after: j) }
      } else {
        while j < text.endIndex && text[j] != " " { j = text.index(after: j) }
      }
      tokenRanges.append(i..<j)
      i = j
    }

    var lines: [String] = []
    var lineStart = 0  // index into tokenRanges
    var lineCharCount = 0

    for idx in tokenRanges.indices {
      let range = tokenRanges[idx]
      let tokenLen = text.distance(from: range.lowerBound, to: range.upperBound)

      if lineCharCount + tokenLen <= width {
        lineCharCount += tokenLen
        continue
      }

      // Token doesn't fit — flush current line if non-empty.
      if lineCharCount > 0 {
        let lineTokens = tokenRanges[lineStart..<idx].map { text[$0] }
        lines.append(lineTokens.joined())
        lineStart = idx
        lineCharCount = 0
      }

      if tokenLen <= width {
        lineStart = idx
        lineCharCount = tokenLen
      } else {
        // Token longer than width — split it.
        var pos = range.lowerBound
        let end = range.upperBound
        while text.distance(from: pos, to: end) > width {
          let chunkEnd = text.index(pos, offsetBy: width)
          lines.append(String(text[pos..<chunkEnd]))
          pos = chunkEnd
        }
        if pos < end {
          tokenRanges[idx] = pos..<end
          lineStart = idx
          lineCharCount = text.distance(from: pos, to: end)
        } else {
          lineStart = idx + 1
          lineCharCount = 0
        }
      }
    }

    // Flush remaining tokens.
    if lineStart < tokenRanges.count {
      let lineTokens = tokenRanges[lineStart...].map { text[$0] }
      lines.append(lineTokens.joined())
    }

    if lines.isEmpty { lines.append("") }
    return lines
  }

  static func inputVisualLines(from buffer: String, textWidth: Int) -> [String] {
    guard textWidth > 0 else { return buffer.isEmpty ? [""] : [] }
    if buffer.isEmpty { return [""] }
    var rows: [String] = []
    for logical in buffer.split(separator: "\n", omittingEmptySubsequences: false) {
      let wrapped = wrappedPlainLines(String(logical), width: textWidth)
      rows.append(contentsOf: wrapped)
    }
    return rows
  }

  static func flattenedRows(from lines: [TLine], width: Int) -> [TLine] {
    guard width > 0 else { return [] }
    var out: [TLine] = []
    for line in lines {
      if line.spans.isEmpty {
        out.append(TLine(spans: []))
        continue
      }

      // Concatenate all span text and track which span each character came from.
      var plain = ""
      var charSpan: [Int] = []  // charSpan[i] = index into line.spans
      for (si, sp) in line.spans.enumerated() {
        plain += sp.text
        charSpan.append(contentsOf: Array(repeating: si, count: sp.text.count))
      }

      if plain.isEmpty {
        out.append(TLine(spans: []))
        continue
      }

      // Split on logical newlines within the concatenated text.
      let chars = Array(plain)
      var i = 0
      while i < chars.count {
        var j = i
        while j < chars.count, chars[j] != "\n" { j &+= 1 }

        let segmentLen = j - i
        if segmentLen > 0 {
          let wrapped = wrappedPlainLines(String(chars[i..<j]), width: width)
          var charOffset = i
          for segment in wrapped {
            let segCount = segment.count
            let sliceSpans = charSpan[charOffset..<(charOffset + segCount)]
            charOffset += segCount
            var newLine = TLine(spans: [])
            var runStart = 0
            while runStart < segCount {
              let si = sliceSpans[sliceSpans.startIndex + runStart]
              let sp = line.spans[si]
              var runEnd = runStart + 1
              while runEnd < segCount,
                sliceSpans[sliceSpans.startIndex + runEnd] == si
              { runEnd += 1 }
              let segStartIdx = segment.startIndex
              let runStartIdx = segment.index(segStartIdx, offsetBy: runStart)
              let runEndIdx = segment.index(segStartIdx, offsetBy: runEnd)
              let text = String(segment[runStartIdx..<runEndIdx])
              if !text.isEmpty {
                newLine.spans.append(
                  StyledSpan(fg: sp.fg, bg: sp.bg, bold: sp.bold, text: text))
              }
              runStart = runEnd
            }
            out.append(newLine)
          }
        } else if j < chars.count {
          out.append(TLine(spans: []))
        }

        guard j < chars.count else { break }
        i = j &+ 1
      }
    }
    return out
  }
}
