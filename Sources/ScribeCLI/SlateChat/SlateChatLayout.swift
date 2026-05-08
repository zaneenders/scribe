import Foundation
import ScribeCore
import SlateCore
import Synchronization

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

// MARK: - Styled transcript model

public struct StyledSpan: Equatable, Sendable {
  public var fg: TerminalRGB
  public var bg: TerminalRGB
  public var bold: Bool
  public var text: String

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

private let slateUserTranscriptHeader = "you:"
private let slateUserTranscriptBodyPrefix = "  "

private func slateIsYouTranscriptHeaderLine(_ line: TLine, theme: CLITheme) -> Bool {
  guard line.spans.count == 1 else { return false }
  let s = line.spans[0]
  return !s.bold
    && s.fg == theme.userPrefix
    && s.bg == theme.background
    && s.text == slateUserTranscriptHeader
}

private func slateIsUserTranscriptBodyLine(_ line: TLine, theme: CLITheme) -> Bool {
  guard let s = line.spans.first, !s.bold, s.bg == theme.background else { return false }
  guard s.fg == theme.userBody else { return false }
  return s.text.hasPrefix(slateUserTranscriptBodyPrefix)
}

private func slateIsUserSubmissionLine(_ line: TLine, theme: CLITheme) -> Bool {
  slateIsYouTranscriptHeaderLine(line, theme: theme) || slateIsUserTranscriptBodyLine(line, theme: theme)
}

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

private struct SinkState {
  var lines: [TLine] = []
  var assistantOpenLine: TLine?
  var assistantOpenLineRaw: String = ""
  /// Index in `lines` where the current assistant section begins (after headers).
  var assistantSectionStartIndex: Int?
  /// The current streaming section (reasoning or answer), tracked so finalize can pick the right theme.
  var currentSection: AssistantStreamSection = .answer
  /// Bumps every time `lines` is modified in the middle (not just appended).
  var lineGeneration: Int = 0
  var wake: ExternalWake?
  var modelBusy: Bool = false
  var coordinatorFinished: Bool = false
  var usageHUD: UsageHUDSnapshot?
  var usageTurnPrompt: Int = 0
  var usageTurnCompletion: Int = 0
  var usageTurnTotal: Int = 0
  var usageSessionPrompt: Int = 0
  var usageSessionCompletion: Int = 0
  var usageSessionTotal: Int = 0
  var contextWindow: Int?
  var banner: BannerSnapshot?
  var queuedTrayText: String? = nil
}

/// Slate-backed transcript sink: accumulates styled transcript lines and renders them via Slate.
public final class SlateTranscriptSink: Sendable {
  private let state = Mutex(SinkState())
  private let markdownRenderer: MarkdownRenderer
  private let theme: CLITheme

  public init(
    markdownRenderer: MarkdownRenderer = SwiftMarkdownRenderer(),
    theme: CLITheme = .default
  ) {
    self.markdownRenderer = markdownRenderer
    self.theme = theme
  }

  private func ping() {
    state.withLock { $0.wake?.requestRender() }
  }

  public func installWake(_ wake: ExternalWake) {
    state.withLock { $0.wake = wake }
  }

  public func markCoordinatorFinished() {
    state.withLock { $0.coordinatorFinished = true }
    ping()
  }

  public func coordinatorFinished() -> Bool {
    state.withLock { $0.coordinatorFinished }
  }

  public func modelTurnBusy() -> Bool {
    state.withLock { $0.modelBusy }
  }

  internal func snapshotTranscriptForLayout() -> (completed: [TLine], open: TLine?, lineGeneration: Int) {
    state.withLock { sink in
      (sink.lines, sink.assistantOpenLine, sink.lineGeneration)
    }
  }

  internal func usageHUDSnapshot() -> UsageHUDSnapshot? {
    state.withLock { $0.usageHUD }
  }

  internal func bannerSnapshot() -> BannerSnapshot? {
    state.withLock { $0.banner }
  }

  /// Records a submitted user turn in the scrollback as a normal (orange/white) entry.
  public func recordUserSubmission(trimmedVisible: String) {
    guard !trimmedVisible.isEmpty else { return }
    let logicalLines =
      trimmedVisible.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    state.withLock { sink in
      sink.lines.append(
        TLine(
          spans: [
            StyledSpan(
              fg: theme.userPrefix, bg: theme.background, bold: false,
              text: slateUserTranscriptHeader)
          ]))
      for row in logicalLines {
        if row.isEmpty {
          sink.lines.append(TLine(spans: []))
          continue
        }
        sink.lines.append(
          TLine(
            spans: [
              StyledSpan(
                fg: theme.userBody, bg: theme.background, bold: false,
                text: slateUserTranscriptBodyPrefix + row)
            ]))
      }
      trimIfNeeded(&sink.lines)
    }
    ping()
  }

  /// Thread-safe setter for the queued tray text — the pipe between the host's
  /// queue state and the renderer.  Called from `SlateChatHost`'s `onEvent`
  /// callback on `@MainActor`.
  public func setQueuedTrayText(_ text: String?) {
    state.withLock { sink in
      sink.queuedTrayText = text
    }
    ping()
  }

  /// Thread-safe snapshot of the current queued tray text for the renderer.
  internal func queuedTrayTextSnapshot() -> String? {
    state.withLock { $0.queuedTrayText }
  }

  public func setContextWindow(_ value: Int?) {
    state.withLock { sink in
      sink.contextWindow = value
    }
  }

  public func setBanner(
    baseURL: String, model: String, cwd: String, scribeVersion: String, gitBranch: String?, sessionId: String
  ) {
    state.withLock { sink in
      sink.banner = BannerSnapshot(
        baseURL: baseURL, model: model, cwd: cwd, scribeVersion: scribeVersion, gitBranch: gitBranch,
        sessionId: sessionId)
    }
    ping()
  }

  // MARK: - Event dispatch

  public func emit(_ event: TranscriptEvent) {
    switch event {
    case .enterAssistantSection(let section, let previous):
      state.withLock { sink in
        sink.currentSection = section
        if previous != nil {
          if let open = sink.assistantOpenLine {
            sink.lines.append(open)
            sink.assistantOpenLine = nil
          }
          if previous == .reasoning && section == .answer {
            sink.lines.append(TLine(spans: []))
          }
        } else {
          if let last = sink.lines.last, slateIsUserSubmissionLine(last, theme: theme) {
            sink.lines.append(TLine(spans: []))
          }
        }
        let header = TLine(
          spans: [
            StyledSpan(
              fg: theme.scribePrefix, bg: theme.background, bold: false, text: "scribe:")
          ])
        sink.lines.append(header)
        switch section {
        case .reasoning:
          sink.lines.append(
            TLine(
              spans: [
                StyledSpan(
                  fg: theme.sectionLabel, bg: theme.background, bold: false,
                  text: "  · reasoning")
              ]))
        case .answer:
          sink.lines.append(
            TLine(
              spans: [
                StyledSpan(
                  fg: theme.sectionLabel, bg: theme.background, bold: false,
                  text: "  · answer")
              ]))
        }
        trimIfNeeded(&sink.lines)
        sink.assistantOpenLine = TLine(spans: [])
        sink.assistantOpenLineRaw = ""
        sink.assistantSectionStartIndex = sink.lines.count
      }
      ping()

    case .appendAssistantText(let section, let text):
      let st = self.style(for: section)
      state.withLock { sink in
        if sink.assistantOpenLine == nil {
          sink.assistantOpenLine = TLine(spans: [])
          sink.assistantOpenLineRaw = ""
        }
        sink.assistantOpenLineRaw += text
        // Fast path during streaming: inline-only styling, no block-level parse.
        let rendered = self.markdownRenderer.renderStreaming(
          text: sink.assistantOpenLineRaw,
          baseFG: st.fg,
          baseBold: st.bold,
          theme: section == .reasoning ? .grayscale : self.theme.markdown
        )
        if let startIdx = sink.assistantSectionStartIndex {
          let removeCount = max(0, sink.lines.count - startIdx)
          if removeCount > 0 {
            sink.lines.removeLast(removeCount)
            sink.lineGeneration += 1
          }
        }
        if rendered.isEmpty {
          sink.assistantOpenLine = TLine(spans: [])
        } else {
          sink.lines.append(contentsOf: rendered.dropLast())
          sink.assistantOpenLine = rendered.last!
        }
      }
      ping()

    case .finalizeAssistantStream:
      state.withLock { sink in
        // Re-render the accumulated text with full block-level markdown.
        if sink.assistantSectionStartIndex != nil {
          let section = sink.currentSection
          let st = self.style(for: section)
          let mdTheme = section == .reasoning ? MarkdownTheme.grayscale : self.theme.markdown
          let fullRender = self.markdownRenderer.render(
            text: sink.assistantOpenLineRaw,
            baseFG: st.fg,
            baseBold: st.bold,
            theme: mdTheme
          )
          // Replace the streaming-rendered lines with the full render.
          if let startIdx = sink.assistantSectionStartIndex {
            let removeCount = max(0, sink.lines.count - startIdx)
            if removeCount > 0 {
              sink.lines.removeLast(removeCount)
              sink.lineGeneration += 1
            }
            if fullRender.isEmpty {
              sink.assistantOpenLine = TLine(spans: [])
            } else {
              sink.lines.append(contentsOf: fullRender.dropLast())
              sink.assistantOpenLine = fullRender.last!
            }
          }
        }
        if let open = sink.assistantOpenLine {
          sink.lines.append(open)
          sink.assistantOpenLine = nil
        }
        sink.assistantOpenLineRaw = ""
        sink.assistantSectionStartIndex = nil
        trimIfNeeded(&sink.lines)
      }
      ping()

    case .emptyAssistantTurn:
      let lineA = TLine(
        spans: [
          StyledSpan(
            fg: theme.scribePrefix, bg: theme.background, bold: false, text: "scribe:")
        ])
      let lineB = TLine(
        spans: [
          StyledSpan(
            fg: theme.emptyTurn, bg: theme.background, bold: false, text: "(empty turn)")
        ])
      state.withLock { sink in
        sink.lines.append(lineA)
        sink.lines.append(lineB)
        trimIfNeeded(&sink.lines)
      }
      ping()

    case .usage(let usage, let tps):
      // Accumulate into both the turn-level totals (reset per user message)
      // and the session-level totals (never reset).  One user turn can produce
      // several `.usage` events when tool calls force multiple LLM rounds.
      guard let triple = usage.scribeReportedPromptCompletionTotal else { break }
      state.withLock { sink in
        sink.usageTurnPrompt += triple.prompt
        sink.usageTurnCompletion += triple.completion
        sink.usageTurnTotal += triple.total
        sink.usageSessionPrompt += triple.prompt
        sink.usageSessionCompletion += triple.completion
        sink.usageSessionTotal += triple.total
        let pct: Int? = {
          guard let cw = sink.contextWindow, cw > 0, triple.prompt > 0 else { return nil }
          return min(100, Int(Double(triple.prompt) / Double(cw) * 100))
        }()
        sink.usageHUD = UsageHUDSnapshot(
          roundPrompt: triple.prompt,
          roundCompletion: triple.completion,
          roundTotal: triple.total,
          turnPrompt: sink.usageTurnPrompt,
          turnCompletion: sink.usageTurnCompletion,
          turnTotal: sink.usageTurnTotal,
          sessionPrompt: sink.usageSessionPrompt,
          sessionCompletion: sink.usageSessionCompletion,
          sessionTotal: sink.usageSessionTotal,
          reasoningTokens: usage.completionTokensDetails?.reasoningTokens,
          cachedPromptTokens: usage.promptTokensDetails?.cachedTokens,
          outputTokensPerSecond: tps,
          contextWindow: sink.contextWindow,
          contextWindowUsedPercent: pct
        )
      }
      ping()

    case .blankLine:
      appendLine(TLine(spans: []))

    case .toolRoundHeader(let round, let toolNames):
      let names = toolNames.joined(separator: ", ")
      let line = TLine(spans: [
        StyledSpan(
          fg: theme.toolRoundHeader, bg: theme.background, bold: true,
          text: "tool round \(round) "),
        StyledSpan(
          fg: theme.toolNames, bg: theme.background, bold: false, text: names),
      ])
      appendLine(line)

    case .toolInvocation(let name, let arguments, let output):
      let argSummary = ToolInvocationFormatting.argumentSummary(name: name, argumentsJSON: arguments)
      let outputLines = ToolInvocationFormatting.outputLines(name: name, jsonOutput: output)
      var spans: [StyledSpan] = [
        StyledSpan(fg: theme.toolInvocation, bg: theme.background, bold: false, text: "▶ \(name)")
      ]
      if let argSummary {
        spans.append(
          StyledSpan(
            fg: theme.toolArgSummary, bg: theme.background, bold: false,
            text: " \(argSummary)"))
      }
      appendLine(TLine(spans: spans))
      for ol in outputLines {
        let indented = TLine(
          spans: [
            StyledSpan(
              fg: theme.toolOutput, bg: theme.background, bold: false,
              text: "  \(ol)")
          ])
        appendLine(indented)
      }

    case .skippedUnreadableStreamLine:
      appendLine(
        TLine(
          spans: [
            StyledSpan(
              fg: theme.skippedStreamLine, bg: theme.background, bold: false,
              text: "(skipped one stream line: not valid completion JSON)")
          ]))

    case .harnessError(let error):
      appendLine(
        TLine(
          spans: [
            StyledSpan(
              fg: theme.errorFG, bg: theme.background, bold: false,
              text: "error: \(error.errorDescription ?? String(describing: error))")
          ]))

    case .turnInterrupted:
      state.withLock { sink in
        sink.lines.append(
          TLine(
            spans: [
              StyledSpan(
                fg: theme.interruptedFG, bg: theme.background, bold: false,
                text: "(interrupted)")
            ]))
        sink.assistantOpenLine = nil
        sink.assistantOpenLineRaw = ""
        sink.assistantSectionStartIndex = nil
        trimIfNeeded(&sink.lines)
      }
      ping()

    case .modelTurnRunning(let running):
      state.withLock { sink in
        sink.modelBusy = running
        if running {
          // New user turn: reset turn-level counters.
          // Session counters are intentionally left alone — they continue
          // accumulating across the entire chat session.
          sink.usageTurnPrompt = 0
          sink.usageTurnCompletion = 0
          sink.usageTurnTotal = 0
          if var u = sink.usageHUD {
            u.roundPrompt = nil
            u.roundCompletion = nil
            u.roundTotal = nil
            u.turnPrompt = 0
            u.turnCompletion = 0
            u.turnTotal = 0
            u.outputTokensPerSecond = nil
            u.reasoningTokens = nil
            u.cachedPromptTokens = nil
            sink.usageHUD = u
          }
        }
      }
      ping()
      if !running {
        let wakeRef = state.withLock { $0.wake }
        if let wakeRef {
          Task.detached(priority: .userInitiated) {
            try? await Task.sleep(for: .milliseconds(50))
            wakeRef.requestRender()
          }
        }
      }
    }
  }

  // MARK: - Private helpers

  private func appendLine(_ line: TLine) {
    state.withLock { sink in
      sink.lines.append(line)
      trimIfNeeded(&sink.lines)
    }
    ping()
  }

  private func trimIfNeeded(_ lines: inout [TLine]) {
    let cap = 4_000
    if lines.count > cap {
      lines.removeFirst(lines.count - cap)
    }
  }

  private func style(for section: AssistantStreamSection) -> (fg: TerminalRGB, bold: Bool) {
    switch section {
    case .reasoning: (theme.reasoningBaseFG, false)
    case .answer: (theme.answerBaseFG, false)
    }
  }
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
    var lineStart = 0          // index into tokenRanges
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
