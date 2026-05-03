import Foundation
import ScribeCore
import ScribeLLM
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

internal struct StyledSpan: Equatable {
  var fg: TerminalRGB
  var bg: TerminalRGB
  var bold: Bool
  var text: String
}

internal struct TLine: Equatable {
  var spans: [StyledSpan]
}

private let slateUserTranscriptHeader = "you:"

private let slateUserTranscriptBodyPrefix = "  "

private func slateIsYouTranscriptHeaderLine(_ line: TLine) -> Bool {
  guard line.spans.count == 1 else { return false }
  let s = line.spans[0]
  return !s.bold
    && s.fg == ScribePalette.orange
    && s.bg == ScribePalette.black
    && s.text == slateUserTranscriptHeader
}

private func slateIsUserTranscriptBodyLine(_ line: TLine) -> Bool {
  guard let s = line.spans.first, !s.bold, s.bg == ScribePalette.black else { return false }
  guard s.fg == ScribePalette.white else { return false }
  return s.text.hasPrefix(slateUserTranscriptBodyPrefix)
}

private func slateIsUserSubmissionLine(_ line: TLine) -> Bool {
  slateIsYouTranscriptHeaderLine(line) || slateIsUserTranscriptBodyLine(line)
}

internal struct UsageHUDSnapshot: Equatable {
  var roundPrompt: Int?
  var roundCompletion: Int?
  var roundTotal: Int?
  var turnPrompt: Int
  var turnCompletion: Int
  var turnTotal: Int
  var sessionPrompt: Int
  var sessionCompletion: Int
  var sessionTotal: Int
  var reasoningTokens: Int?
  var cachedPromptTokens: Int?
  var outputTokensPerSecond: Double?
}

internal struct BannerSnapshot: Equatable {
  var baseURL: String
  var model: String
  var cwd: String
}

private struct SinkState {
  var lines: [TLine] = []
  var assistantOpenLine: TLine?
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
  var banner: BannerSnapshot?
  /// Optional message held in the queued tray (a dedicated UI strip above the input area, not
  /// part of scrollback). Populated by the host while the agent is busy; cleared when the message
  /// is sent to the coordinator (via interrupt or natural turn-end flush) or when the user
  /// recalls it with Ctrl+C.
  var queuedTrayText: String? = nil
}

/// Slate-backed transcript sink: same information as ``TerminalScribeOutput``, with truecolor preserved in the grid.
public final class SlateTranscriptSink: ScribeAgentOutput, Sendable {
  private let state = Mutex(SinkState())

  public init() {}

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

  internal func snapshotTranscriptForLayout() -> (completed: [TLine], open: TLine?) {
    state.withLock { sink in
      (sink.lines, sink.assistantOpenLine)
    }
  }

  private func snapshotLines() -> [TLine] {
    state.withLock { sink in
      var out = sink.lines
      if let open = sink.assistantOpenLine {
        out.append(open)
      }
      return out
    }
  }

  internal func usageHUDSnapshot() -> UsageHUDSnapshot? {
    state.withLock { $0.usageHUD }
  }

  internal func bannerSnapshot() -> BannerSnapshot? {
    state.withLock { $0.banner }
  }

  /// Records a submitted user turn in the scrollback as a normal (orange/white) entry.
  /// Hosts call this when the coordinator actually picks the message up via the user-line gate, so
  /// queued-tray submissions only appear in scrollback at the moment they are dispatched (not while
  /// they sit in the tray).
  public func recordUserSubmission(trimmedVisible: String) {
    guard !trimmedVisible.isEmpty else { return }
    let logicalLines =
      trimmedVisible.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    state.withLock { sink in
      sink.lines.append(
        TLine(
          spans: [
            StyledSpan(
              fg: ScribePalette.orange, bg: ScribePalette.black, bold: false,
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
                fg: ScribePalette.white, bg: ScribePalette.black, bold: false,
                text: slateUserTranscriptBodyPrefix + row)
            ]))
      }
      trimIfNeeded(&sink.lines)
    }
    ping()
  }

  /// Sets (or clears) the queued-tray banner that displays an in-flight user submission while the
  /// agent is busy. The text is rendered in a dedicated strip above the input row.
  public func setQueuedTrayText(_ text: String?) {
    state.withLock { sink in
      sink.queuedTrayText = text
    }
    ping()
  }

  /// Snapshot of the current queued-tray text (used by the renderer).
  internal func queuedTrayTextSnapshot() -> String? {
    state.withLock { $0.queuedTrayText }
  }

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

  private static func style(for section: AssistantStreamSection) -> (fg: TerminalRGB, bold: Bool) {
    switch section {
    case .reasoning: (ScribePalette.thinking, true)
    case .answer: (ScribePalette.cyan, false)
    }
  }

  private static func appendText(to line: inout TLine, fg: TerminalRGB, bg: TerminalRGB, bold: Bool, text: String) {
    guard !text.isEmpty else { return }
    if var last = line.spans.last, last.fg == fg, last.bg == bg, last.bold == bold {
      last.text += text
      line.spans[line.spans.count - 1] = last
    } else {
      line.spans.append(StyledSpan(fg: fg, bg: bg, bold: bold, text: text))
    }
  }

  public func markModelTurnRunning(_ running: Bool) throws {
    state.withLock { sink in
      sink.modelBusy = running
      if running {
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
    // The pump's external-wake throttle (`latest: true`) is supposed to deliver the trailing
    // tick at the end of a burst, but in practice an SSE stream can call `requestRender()`
    // 30+ times/sec right up to `markModelTurnRunning(false)` and the throttle window may
    // happen to be "between" emissions when we flip idle. Without a follow-up, the spinner
    // stays hot until the next stdin/resize event. Ping again after the throttle interval to
    // guarantee the UI catches up.
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

  public func printConfigBanner(baseURL: String, model: String, cwd: String) {
    state.withLock { sink in
      sink.banner = BannerSnapshot(baseURL: baseURL, model: model, cwd: cwd)
    }
    ping()
  }

  public func printUserPromptDecoration() {}

  public func enterAssistantStreamSection(
    _ section: AssistantStreamSection,
    previous: AssistantStreamSection?
  ) throws {
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
        if let last = sink.lines.last, slateIsUserSubmissionLine(last) {
          sink.lines.append(TLine(spans: []))
        }
      }

      let header = TLine(
        spans: [
          StyledSpan(
            fg: ScribePalette.purple, bg: ScribePalette.black, bold: false, text: "scribe:")
        ])
      sink.lines.append(header)
      switch section {
      case .reasoning:
        sink.lines.append(
          TLine(
            spans: [
              StyledSpan(
                fg: ScribePalette.grayDim, bg: ScribePalette.black, bold: false, text: "  · reasoning")
            ]))
      case .answer:
        sink.lines.append(
          TLine(
            spans: [
              StyledSpan(
                fg: ScribePalette.grayDim, bg: ScribePalette.black, bold: false, text: "  · answer")
            ]))
      }
      trimIfNeeded(&sink.lines)

      sink.assistantOpenLine = TLine(spans: [])
    }
    ping()
  }

  public func appendAssistantStreamText(_ section: AssistantStreamSection, text: String) throws {
    let st = Self.style(for: section)
    let parts = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    for (i, part) in parts.enumerated() {
      state.withLock { sink in
        if sink.assistantOpenLine == nil {
          sink.assistantOpenLine = TLine(spans: [])
        }
        Self.appendText(
          to: &sink.assistantOpenLine!, fg: st.fg, bg: ScribePalette.black, bold: st.bold, text: part)
        if i + 1 < parts.count {
          if let open = sink.assistantOpenLine {
            sink.lines.append(open)
            sink.assistantOpenLine = TLine(spans: [])
          }
        }
      }
      ping()
    }
  }

  public func finalizeAssistantStreamIfNeeded(streamHadVisibleTokens: Bool) throws {
    guard streamHadVisibleTokens else { return }
    state.withLock { sink in
      if let open = sink.assistantOpenLine {
        sink.lines.append(open)
        sink.assistantOpenLine = nil
      }
      trimIfNeeded(&sink.lines)
    }
    ping()
  }

  /// Flushes optional open assistant reply after a streamed-style replay (`enterAssistantStreamSection` + optional `appendAssistantStreamText`).
  public func endReplayedAssistantSection(answerHadVisibleCharacters: Bool) throws {
    state.withLock { sink in
      if let open = sink.assistantOpenLine {
        let hasSpanText = open.spans.contains { !$0.text.isEmpty }
        if answerHadVisibleCharacters || hasSpanText {
          sink.lines.append(open)
        }
        sink.assistantOpenLine = nil
      }
      trimIfNeeded(&sink.lines)
    }
    ping()
  }

  /// Replays prior turns from a persisted message list (skips system rows). Used when resuming a session.
  public func replayPersistedConversation(_ messages: [Components.Schemas.ChatMessage]) throws {
    var i = 0
    while i < messages.count, messages[i].role == .system {
      i += 1
    }
    var toolRoundCounter = 0
    while i < messages.count {
      let msg = messages[i]
      switch msg.role {
      case .system:
        i += 1
      case .user:
        let t = (msg.content ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty {
          recordUserSubmission(trimmedVisible: t)
        }
        i += 1
      case .assistant:
        let text = msg.content ?? ""
        let visibleTrimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let calls = msg.toolCalls ?? []

        try enterAssistantStreamSection(.answer, previous: nil)
        if !text.isEmpty {
          try appendAssistantStreamText(.answer, text: text)
        }
        try endReplayedAssistantSection(answerHadVisibleCharacters: !visibleTrimmed.isEmpty)

        if !calls.isEmpty {
          toolRoundCounter += 1
          let names = calls.map { $0.function?.name ?? "(tool)" }
          try printToolRoundHeader(round: toolRoundCounter, toolNames: names)

          var k = i + 1
          var toolBodies: [String: String] = [:]
          while k < messages.count, messages[k].role == .tool {
            if let tid = messages[k].toolCallId {
              toolBodies[tid] = messages[k].content ?? ""
            }
            k += 1
          }

          for tc in calls {
            let id = tc.id ?? ""
            let name = tc.function?.name ?? "tool"
            let args = tc.function?.arguments ?? "{}"
            let jsonOut = toolBodies[id] ?? ""
            let argSummary = ToolInvocationFormatting.argumentSummary(name: name, argumentsJSON: args)
            let lines = ToolInvocationFormatting.outputLines(name: name, jsonOutput: jsonOut)
            try printToolInvocation(name: name, argumentSummary: argSummary, outputLines: lines)
            try printBlankLine()
          }
          i = k
        } else {
          i += 1
        }
        try printBlankLine()
      case .tool:
        i += 1
      }
    }
  }

  public func printEmptyAssistantTurn() throws {
    let lineA = TLine(
      spans: [
        StyledSpan(
          fg: ScribePalette.purple, bg: ScribePalette.black, bold: false, text: "scribe:")
      ])
    let lineB = TLine(
      spans: [
        StyledSpan(
          fg: ScribePalette.grayDim, bg: ScribePalette.black, bold: false, text: "(empty turn)")
      ])
    state.withLock { sink in
      sink.lines.append(lineA)
      sink.lines.append(lineB)
      trimIfNeeded(&sink.lines)
    }
    ping()
  }

  public func emitUsage(
    usage: Components.Schemas.CompletionUsage?,
    outputTokensPerSecond: Double?
  ) throws {
    guard let usage, let triple = usage.scribeReportedPromptCompletionTotal else { return }
    state.withLock { sink in
      sink.usageTurnPrompt += triple.prompt
      sink.usageTurnCompletion += triple.completion
      sink.usageTurnTotal += triple.total
      sink.usageSessionPrompt += triple.prompt
      sink.usageSessionCompletion += triple.completion
      sink.usageSessionTotal += triple.total
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
        outputTokensPerSecond: outputTokensPerSecond
      )
    }
    ping()
  }

  public func printBlankLine() throws {
    appendLine(TLine(spans: []))
  }

  public func printToolRoundHeader(round: Int, toolNames: [String]) throws {
    let names = toolNames.joined(separator: ", ")
    let line = TLine(spans: [
      StyledSpan(
        fg: ScribePalette.yellow, bg: ScribePalette.black, bold: true,
        text: "tool round \(round) "),
      StyledSpan(
        fg: ScribePalette.toolName, bg: ScribePalette.black, bold: false, text: names),
    ])
    appendLine(line)
  }

  public func printToolInvocation(
    name: String,
    argumentSummary: String?,
    outputLines: [String]
  ) throws {
    var spans: [StyledSpan] = [
      StyledSpan(fg: ScribePalette.yellow, bg: ScribePalette.black, bold: false, text: "▶ \(name)")
    ]
    if let argumentSummary {
      spans.append(
        StyledSpan(
          fg: ScribePalette.grayDim, bg: ScribePalette.black, bold: false,
          text: " \(argumentSummary)"))
    }
    appendLine(TLine(spans: spans))
    for ol in outputLines {
      let indented =
        TLine(
          spans: [
            StyledSpan(
              fg: ScribePalette.white, bg: ScribePalette.black, bold: false,
              text: "  \(ol)")
          ])
      appendLine(indented)
    }
  }

  public func printMaxToolRoundsExceeded(max: Int) throws {
    appendLine(
      TLine(
        spans: [
          StyledSpan(
            fg: ScribePalette.yellow, bg: ScribePalette.black, bold: false,
            text: "Stopped: max tool rounds (\(max)) exceeded.")
        ]))
  }

  public func printSkippedUnreadableStreamLine() throws {
    appendLine(
      TLine(
        spans: [
          StyledSpan(
            fg: ScribePalette.grayDim, bg: ScribePalette.black, bold: false,
            text: "(skipped one stream line: not valid completion JSON)")
        ]))
  }

  public func printHarnessRunError(_ error: Error) throws {
    appendLine(
      TLine(
        spans: [
          StyledSpan(
            fg: ScribePalette.red, bg: ScribePalette.black, bold: false,
            text: "error: \(error)")
        ]))
  }

  public func printTurnInterrupted() throws {
    state.withLock { sink in
      sink.lines.append(
        TLine(
          spans: [
            StyledSpan(
              fg: ScribePalette.grayDim, bg: ScribePalette.black, bold: false,
              text: "(interrupted)")
          ]))
      trimIfNeeded(&sink.lines)
    }
    ping()
  }
}

// MARK: - Layout

internal enum TranscriptLayout {
  private struct RunStyle: Equatable {
    var fg: TerminalRGB
    var bg: TerminalRGB
    var bold: Bool
  }

  private static func runStyle(from s: StyledSpan) -> RunStyle {
    RunStyle(fg: s.fg, bg: s.bg, bold: s.bold)
  }

  private static func wrappedPlainLines(_ text: String, width: Int) -> [String] {
    guard width > 0 else { return [] }
    if text.isEmpty { return [""] }
    var lines: [String] = []
    var current = ""

    func flush() {
      if !current.isEmpty {
        lines.append(current)
        current = ""
      }
    }

    for word in text.split(separator: " ", omittingEmptySubsequences: false) {
      let w = String(word)
      let sep = current.isEmpty ? "" : " "
      let candidate = current + sep + w
      if candidate.count <= width {
        current = candidate
        continue
      }

      flush()

      if w.count <= width {
        current = w
        continue
      }

      var rest = Substring(w)
      while !rest.isEmpty {
        let take = min(width, rest.count)
        lines.append(String(rest.prefix(take)))
        rest = rest.dropFirst(take)
      }
    }

    flush()
    // Strings that are only U+0020 spaces split into empty chunks above, leaving `lines` empty.
    // That drops blank transcript rows (`you:` continuation with no trailing text).
    if lines.isEmpty, !text.isEmpty {
      var remainder = Substring(text)
      while remainder.count > width {
        lines.append(String(remainder.prefix(width)))
        remainder = remainder.dropFirst(width)
      }
      lines.append(String(remainder))
    }

    return lines
  }

  /// Wrapped display lines for the input buffer (logical newlines + word wrap).
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

  /// Flattens styled transcript lines into wrapped rows of ``TLine``.
  static func flattenedRows(from lines: [TLine], width: Int) -> [TLine] {
    guard width > 0 else { return [] }
    var out: [TLine] = []
    for line in lines {
      if line.spans.isEmpty {
        out.append(TLine(spans: []))
        continue
      }

      var plain = ""
      var styles: [RunStyle] = []
      for sp in line.spans {
        for ch in sp.text {
          plain.append(ch)
          styles.append(runStyle(from: sp))
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
              SlateTranscriptSinkAppendSpan(
                &newLine, fg: style.fg, bg: style.bg, bold: style.bold, char: ch)
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

/// Helper to append one character span (file-private linkage to avoid exposing on sink).
internal func SlateTranscriptSinkAppendSpan(
  _ line: inout TLine, fg: TerminalRGB, bg: TerminalRGB, bold: Bool, char: Character
) {
  if var last = line.spans.last, last.fg == fg, last.bg == bg, last.bold == bold {
    last.text.append(char)
    line.spans[line.spans.count - 1] = last
  } else {
    line.spans.append(StyledSpan(fg: fg, bg: bg, bold: bold, text: String(char)))
  }
}
