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
}

private struct SinkState {
  var lines: [TLine] = []
  var assistantOpenLine: TLine?
  var assistantOpenLineRaw: String = ""
  /// Index in `lines` where the current assistant section begins (after headers).
  var assistantSectionStartIndex: Int?
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
  /// Live message count mirrored from the canonical rope so the viewport
  /// trimmer can consult it without holding a stale rope copy.
  var messageCount: Int? = nil
  /// TLine indices where new messages start (used for viewport trimming).
  var messageBoundaryIndices: [Int] = []
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

  public func snapshotTranscriptForLayout() -> (completed: [TLine], open: TLine?, lineGeneration: Int) {
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
      // Track message boundary: `you:` starts a new message.
      sink.messageBoundaryIndices.append(sink.lines.count)
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
      trimIfNeeded(sink: &sink)
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

  /// Mirrors the live message count from the canonical rope so the viewport
  /// trimmer can consult it without holding a stale rope copy.
  public func setMessageCount(_ count: Int) {
    state.withLock { sink in
      sink.messageCount = count
    }
  }

  public func setBanner(baseURL: String, model: String, cwd: String, scribeVersion: String, gitBranch: String?) {
    state.withLock { sink in
      sink.banner = BannerSnapshot(
        baseURL: baseURL, model: model, cwd: cwd, scribeVersion: scribeVersion, gitBranch: gitBranch)
    }
    ping()
  }

  // MARK: - Event dispatch

  public func emit(_ event: TranscriptEvent) {
    switch event {
    case .enterAssistantSection(let section, let previous):
      state.withLock { sink in
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
        if previous == nil {
          sink.messageBoundaryIndices.append(sink.lines.count)
        }
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
        trimIfNeeded(sink: &sink)
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
        let rendered = self.markdownRenderer.render(
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
        if let open = sink.assistantOpenLine {
          sink.lines.append(open)
          sink.assistantOpenLine = nil
        }
        sink.assistantOpenLineRaw = ""
        sink.assistantSectionStartIndex = nil
        trimIfNeeded(sink: &sink)
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
        sink.messageBoundaryIndices.append(sink.lines.count)
        sink.lines.append(lineA)
        sink.lines.append(lineB)
        trimIfNeeded(sink: &sink)
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
        trimIfNeeded(sink: &sink)
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

    case .messageCountChanged(let count):
      state.withLock { sink in
        sink.messageCount = count
        // Ensure boundary array stays in sync with the rope so the
        // trimmer can locate cut points for every message.
        while sink.messageBoundaryIndices.count < count {
          sink.messageBoundaryIndices.append(sink.lines.count)
        }
        // Fire the trim check now that the count may have crossed
        // the maxRenderedMessages threshold.
        trimIfNeeded(sink: &sink)
      }
    }
  }

  // MARK: - Private helpers

  private func appendLine(_ line: TLine) {
    state.withLock { sink in
      // Track message boundaries: a `you:` header starts a new message.
      // (`scribe:` headers are tracked directly in enterAssistantSection /
      // emptyAssistantTurn.)
      if let firstSpan = line.spans.first, firstSpan.text == slateUserTranscriptHeader {
        sink.messageBoundaryIndices.append(sink.lines.count)
      }
      sink.lines.append(line)
      trimIfNeeded(sink: &sink)
    }
    ping()
  }

  /// Caps re-parse cost to ~34 messages regardless of session length.
  /// For an 80 × 24 terminal: 24 viewport messages + 10 scroll buffer
  /// (5 above and 5 below).
  private static let maxRenderedMessages = 34

  private func trimIfNeeded(sink: inout SinkState) {
    // Primary path: rope-driven viewport trimming.  The canonical rope is the
    // source of truth for message count; boundaries track where each message
    // starts in the TLine array (synced on every `.messageCountChanged`).
    if let totalMessages = sink.messageCount,
      totalMessages > Self.maxRenderedMessages
    {
      // Drop the oldest messages so we keep at most maxRenderedMessages.
      let dropMessageCount = totalMessages - Self.maxRenderedMessages
      let boundaries = sink.messageBoundaryIndices
      // Use the boundary array to find the line-level cut point.
      // (boundaries may lag by one event; clamp to available entries.)
      let dropIdx = min(dropMessageCount, boundaries.count)
      if dropIdx > 0, dropIdx <= boundaries.count {
        let dropLineIdx = boundaries[dropIdx - 1]
        sink.lines = Array(sink.lines[dropLineIdx...])
        // Adjust remaining boundary indices.
        sink.messageBoundaryIndices = Array(
          sink.messageBoundaryIndices[dropIdx...].map { $0 - dropLineIdx }
        )
        sink.lineGeneration += 1
        return
      }
    }

    // Fallback: hard line cap.
    let cap = 4_000
    if sink.lines.count > cap {
      let drop = sink.lines.count - cap
      sink.lines = Array(sink.lines[drop...])
      // Shift boundary indices.
      sink.messageBoundaryIndices = sink.messageBoundaryIndices.compactMap {
        let shifted = $0 - drop
        return shifted >= 0 ? shifted : nil
      }
      sink.lineGeneration += 1
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

    // Tokenize into alternating word / space sequences so leading/trailing
    // spaces are preserved.
    var tokens: [String] = []
    var i = text.startIndex
    while i < text.endIndex {
      if text[i] == " " {
        var j = i
        while j < text.endIndex && text[j] == " " {
          j = text.index(after: j)
        }
        tokens.append(String(text[i..<j]))
        i = j
      } else {
        var j = i
        while j < text.endIndex && text[j] != " " {
          j = text.index(after: j)
        }
        tokens.append(String(text[i..<j]))
        i = j
      }
    }

    var lines: [String] = []
    var current = ""

    func flush() {
      lines.append(current)
      current = ""
    }

    for token in tokens {
      let candidate = current + token
      if candidate.count <= width {
        current = candidate
        continue
      }

      if !current.isEmpty {
        flush()
      }

      if token.count <= width {
        current = token
      } else {
        // Token longer than width — must be a word (spaces are always <= width).
        var rest = Substring(token)
        while rest.count > width {
          lines.append(String(rest.prefix(width)))
          rest = rest.dropFirst(width)
        }
        current = String(rest)
      }
    }

    if !current.isEmpty || !lines.isEmpty {
      lines.append(current)
    }

    if lines.isEmpty {
      lines.append("")
    }

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

      var plain = ""
      var styles: [(fg: TerminalRGB, bg: TerminalRGB, bold: Bool)] = []
      for sp in line.spans {
        let s = (fg: sp.fg, bg: sp.bg, bold: sp.bold)
        for ch in sp.text {
          plain.append(ch)
          styles.append(s)
        }
      }

      if plain.isEmpty {
        out.append(TLine(spans: []))
        continue
      }

      let chars = Array(plain)
      precondition(chars.count == styles.count)

      var i = 0
      while i < chars.count {
        var j = i
        while j < chars.count, chars[j] != "\n" {
          j &+= 1
        }

        let part = chars[i..<j]
        if !part.isEmpty {
          let wrapped = wrappedPlainLines(String(part), width: width)
          var charOffset = i
          for segment in wrapped {
            let sliceStyles = styles[charOffset..<(charOffset + segment.count)]
            charOffset += segment.count
            var newLine = TLine(spans: [])
            for (style, ch) in zip(sliceStyles, segment) {
              if let lastIdx = newLine.spans.indices.last,
                newLine.spans[lastIdx].fg == style.fg,
                newLine.spans[lastIdx].bg == style.bg,
                newLine.spans[lastIdx].bold == style.bold
              {
                newLine.spans[lastIdx].text.append(ch)
              } else {
                newLine.spans.append(
                  StyledSpan(fg: style.fg, bg: style.bg, bold: style.bold, text: String(ch)))
              }
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
