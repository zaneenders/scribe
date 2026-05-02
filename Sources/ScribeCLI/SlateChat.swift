import Foundation
import Logging
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

// MARK: - User input

private actor UserLineGate {
  private var waiting: CheckedContinuation<String?, Never>?
  private var queue: [String] = []

  func nextLine() async -> String? {
    if !queue.isEmpty {
      return queue.removeFirst()
    }
    return await withCheckedContinuation { cont in
      waiting = cont
    }
  }

  func complete(_ line: String?) {
    if let cont = waiting {
      cont.resume(returning: line)
      waiting = nil
    } else if let line {
      queue.append(line)
    }
  }
}

/// Cooperative abort for Ctrl+C during an assistant/tool round without cancelling the long-lived coordinator task.
private final class ModelTurnInterruptFlag: @unchecked Sendable {
  private let lock = Mutex(false)

  func clear() {
    lock.withLock { $0 = false }
  }

  func request() {
    lock.withLock { $0 = true }
  }

  func peek() -> Bool {
    lock.withLock { $0 }
  }
}

// MARK: - Transcript model (thread-safe for streaming + render)

private struct StyledSpan: Equatable {
  var fg: TerminalRGB
  var bg: TerminalRGB
  var bold: Bool
  var text: String
}

private struct TLine: Equatable {
  var spans: [StyledSpan]
}

/// Standalone transcript header (parity with purple ``scribe:``).
private let slateUserTranscriptHeader = "you:"

/// Indents user message lines under ``slateUserTranscriptHeader`` (same as ``  · reasoning``).
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

/// Any scrollback line that belongs to a submitted user turn (header or body).
private func slateIsUserSubmissionLine(_ line: TLine) -> Bool {
  slateIsYouTranscriptHeaderLine(line) || slateIsUserTranscriptBodyLine(line)
}

/// Latest usage for the fixed top row (not part of scrollback).
private struct UsageHUDSnapshot: Equatable {
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

/// Config header fixed at the top (not scrollback).
private struct BannerSnapshot: Equatable {
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
public final class SlateTranscriptSink: ScribeAgentOutput, @unchecked Sendable {
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

  fileprivate func snapshotTranscriptForLayout() -> (completed: [TLine], open: TLine?) {
    state.withLock { sink in
      (sink.lines, sink.assistantOpenLine)
    }
  }

  fileprivate func snapshotLines() -> [TLine] {
    state.withLock { sink in
      var out = sink.lines
      if let open = sink.assistantOpenLine {
        out.append(open)
      }
      return out
    }
  }

  fileprivate func usageHUDSnapshot() -> UsageHUDSnapshot? {
    state.withLock { $0.usageHUD }
  }

  fileprivate func bannerSnapshot() -> BannerSnapshot? {
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
  fileprivate func queuedTrayTextSnapshot() -> String? {
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

private enum TranscriptLayout {
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
private func SlateTranscriptSinkAppendSpan(
  _ line: inout TLine, fg: TerminalRGB, bg: TerminalRGB, bold: Bool, char: Character
) {
  if var last = line.spans.last, last.fg == fg, last.bg == bg, last.bold == bold {
    last.text.append(char)
    line.spans[line.spans.count - 1] = last
  } else {
    line.spans.append(StyledSpan(fg: fg, bg: bg, bold: bold, text: String(char)))
  }
}

// MARK: - Grid render

@MainActor
private enum SlateChatRenderer {
  /// Braille spinner (common in TUIs); one cell, advances while waiting for the first token.
  private static let llmWaitSpinner: [Character] = [
    "⣾", "⣽", "⣻", "⢿", "⡿", "⣟", "⣯", "⣷",
  ]

  private static let inputGutterColumns = 5
  /// Width of `queued: ` prefix; continuation rows under the queued tray indent to align under text.
  private static let queuedTrayGutterColumns = 8
  /// Hard cap on tray rows so a long queued message can't push the transcript off-screen.
  private static let queuedTrayMaxRows = 4

  /// Wrapped tray rows for an optional queued submission, capped by ``queuedTrayMaxRows``.
  /// Returns an empty array when ``queuedTrayText`` is nil/empty.
  private static func queuedTrayVisualLines(
    queuedTrayText: String?,
    textWidth: Int
  ) -> [String] {
    guard let raw = queuedTrayText, !raw.isEmpty, textWidth > 0 else { return [] }
    let normalized = raw.replacingOccurrences(of: "\r\n", with: "\n")
    let lines = TranscriptLayout.inputVisualLines(from: normalized, textWidth: textWidth)
    if lines.count <= queuedTrayMaxRows { return lines }
    var capped = Array(lines.prefix(queuedTrayMaxRows))
    if !capped.isEmpty {
      var last = capped[capped.count - 1]
      if last.count > 1 {
        last = String(last.prefix(max(1, last.count - 1))) + "…"
      } else {
        last = "…"
      }
      capped[capped.count - 1] = last
    }
    return capped
  }

  /// Number of rows to reserve for the queued tray strip (0 when no queued message).
  static func queuedTrayRowCount(
    queuedTrayText: String?,
    cols: Int
  ) -> Int {
    let textWidth = max(0, cols &- queuedTrayGutterColumns)
    let lines = queuedTrayVisualLines(queuedTrayText: queuedTrayText, textWidth: textWidth)
    return lines.count
  }

  /// Rows available for transcript text between the fixed header and the input stack (matches ``makeGrid``).
  static func transcriptContentRows(
    cols: Int,
    rows: Int,
    banner: BannerSnapshot?,
    usage: UsageHUDSnapshot?,
    inputLine: String,
    waitingForLLM: Bool,
    queuedTrayText: String?
  ) -> Int {
    let headerRows: Int = {
      if banner != nil {
        return min(3, max(0, rows &- 1))
      }
      if usage != nil, rows >= 2 {
        return min(3, max(1, rows &- 1))
      }
      return 0
    }()

    let showSpinner = waitingForLLM && inputLine.isEmpty
    let textWidth = max(0, cols &- inputGutterColumns)
    let maxInputRows = min(8, max(1, rows &- headerRows &- 1))
    let inputRowCount: Int
    if showSpinner || textWidth == 0 {
      inputRowCount = 1
    } else {
      var lines = TranscriptLayout.inputVisualLines(from: inputLine, textWidth: textWidth)
      let needsExtraCursorRow =
        lines.last.map { $0.count >= textWidth && textWidth > 0 } ?? false
      if needsExtraCursorRow {
        lines.append("")
      }
      let capped = min(maxInputRows, max(1, lines.count))
      inputRowCount = capped
    }

    let trayRowCount = queuedTrayRowCount(queuedTrayText: queuedTrayText, cols: cols)
    let firstInputRow = rows &- inputRowCount
    let firstTrayRow = max(headerRows, firstInputRow &- trayRowCount)
    return max(0, firstTrayRow &- headerRows)
  }

  static func makeGrid(
    cols: Int,
    rows: Int,
    flattenedTranscript: [TLine],
    transcriptTailStart: Int,
    banner: BannerSnapshot?,
    usage: UsageHUDSnapshot?,
    inputLine: String,
    llmWaitAnimationFrame: Int,
    waitingForLLM: Bool,
    queuedTrayText: String?
  ) -> TerminalCellGrid {
    var grid = TerminalCellGrid(
      cols: cols,
      rows: rows,
      filling: TerminalCell(
        glyph: " ", foreground: ScribePalette.white, background: ScribePalette.black, flags: []))

    let headerRows: Int = {
      if banner != nil {
        return min(3, max(0, rows &- 1))
      }
      if usage != nil, rows >= 2 {
        return min(3, max(1, rows &- 1))
      }
      return 0
    }()

    let contentRows = transcriptContentRows(
      cols: cols, rows: rows, banner: banner, usage: usage,
      inputLine: inputLine, waitingForLLM: waitingForLLM,
      queuedTrayText: queuedTrayText)

    let usageReserve: Int = {
      guard let u = usage else { return 0 }
      let w = usageHUDCharCount(u, maxRows: headerRows)
      return min(cols, w &+ 1)
    }()
    let bannerMaxWithUsage = usageReserve > 0 ? max(0, cols &- usageReserve) : cols

    if headerRows >= 1 {
      if let banner {
        paintBannerKV(
          into: &grid, row: 0, cols: cols, maxWidth: bannerMaxWithUsage, label: "LLM: ",
          value: banner.baseURL)
      }
      if let u = usage {
        paintUsageHUD(into: &grid, cols: cols, usage: u, maxRows: headerRows)
      }
    }

    if headerRows >= 2, let banner {
      paintBannerKV(
        into: &grid, row: 1, cols: cols, maxWidth: bannerMaxWithUsage, label: "Model: ",
        value: banner.model)
    }
    if headerRows >= 3, let banner {
      paintBannerKV(
        into: &grid, row: 2, cols: cols, maxWidth: bannerMaxWithUsage, label: "CWD: ", value: banner.cwd)
    }

    let showSpinner = waitingForLLM && inputLine.isEmpty
    let textWidth = max(0, cols &- inputGutterColumns)
    let maxInputRows = min(8, max(1, rows &- headerRows &- 1))
    let visualLines: [String]
    let inputRowCount: Int
    if showSpinner || textWidth == 0 {
      visualLines = []
      inputRowCount = 1
    } else {
      var lines = TranscriptLayout.inputVisualLines(from: inputLine, textWidth: textWidth)
      let needsExtraCursorRow =
        lines.last.map { $0.count >= textWidth && textWidth > 0 } ?? false
      if needsExtraCursorRow {
        lines.append("")
      }
      let capped = min(maxInputRows, max(1, lines.count))
      inputRowCount = capped
      visualLines =
        lines.count > capped
        ? Array(lines.suffix(capped))
        : lines + Array(repeating: "", count: max(0, capped &- lines.count))
    }

    let firstInputRow = rows &- inputRowCount
    let trayTextWidth = max(0, cols &- queuedTrayGutterColumns)
    let rawTrayLines = queuedTrayVisualLines(
      queuedTrayText: queuedTrayText, textWidth: trayTextWidth)
    // Cap tray rows so an oversized tray on a tiny terminal can't overpaint the input strip.
    let availableTrayRows = max(0, firstInputRow &- headerRows)
    let trayVisualLines = Array(rawTrayLines.prefix(availableTrayRows))
    let trayRowCount = trayVisualLines.count
    let firstTrayRow = max(headerRows, firstInputRow &- trayRowCount)
    let wrapW = cols

    fillInputBackground(
      into: &grid, startRow: firstTrayRow, rowCount: trayRowCount &+ inputRowCount, cols: cols,
      background: ScribePalette.inputAreaBg
    )

    if contentRows > 0 {
      let flat = flattenedTranscript
      let maxTailStart = max(0, flat.count &- contentRows)
      let tailStart = min(max(0, transcriptTailStart), maxTailStart)
      let visibleCount = min(contentRows, flat.count &- tailStart)
      let visible = visibleCount > 0 ? Array(flat[tailStart..<(tailStart &+ visibleCount)]) : []
      let topPad = contentRows &- visible.count
      var y = headerRows &+ topPad
      for line in visible {
        guard y < firstTrayRow else { break }
        blit(line: line, into: &grid, column: 0, row: y, width: wrapW)
        y &+= 1
      }
    }

    if trayRowCount > 0 {
      paintQueuedTrayRows(
        into: &grid,
        startRow: firstTrayRow,
        cols: cols,
        textWidth: trayTextWidth,
        visualLines: trayVisualLines)
    }

    paintInputRows(
      into: &grid,
      startRow: firstInputRow,
      cols: cols,
      textWidth: textWidth,
      visualLines: visualLines,
      rowCount: inputRowCount,
      llmWaitAnimationFrame: llmWaitAnimationFrame,
      showSpinner: showSpinner)

    return grid
  }

  private static func formatUsageInt(_ n: Int) -> String {
    ScribeUsageFormatting.groupingInt(n)
  }

  private static func formatUsageIntOpt(_ n: Int?) -> String {
    guard let n else { return "—" }
    return formatUsageInt(n)
  }

  private static func uSpan(_ fg: TerminalRGB, _ text: String, bold: Bool = false) -> StyledSpan {
    StyledSpan(fg: fg, bg: ScribePalette.black, bold: bold, text: text)
  }

  /// Up to three lines, aligned with the three-row config banner: (1) last request in/out/rate, (2) optional R+cache, (3) turn and session Σ.
  /// When ``maxRows`` is smaller than the full set, the optional R/cache row is dropped first so totals stay visible.
  private static func usageHUDLines(from usage: UsageHUDSnapshot, maxRows: Int) -> [TLine] {
    let sep = "  ·  "

    var row0: [StyledSpan] = [
      uSpan(ScribePalette.usageLabel, "in "),
      uSpan(ScribePalette.usagePrompt, formatUsageIntOpt(usage.roundPrompt)),
      uSpan(ScribePalette.usageMuted, sep),
      uSpan(ScribePalette.usageLabel, "out "),
      uSpan(ScribePalette.usageCompletion, formatUsageIntOpt(usage.roundCompletion)),
    ]
    if let tps = usage.outputTokensPerSecond {
      row0.append(uSpan(ScribePalette.usageMuted, sep))
      row0.append(uSpan(ScribePalette.usageLabel, "rate "))
      row0.append(uSpan(ScribePalette.usageRate, String(format: "%.1f/s", tps)))
    }
    let line0 = TLine(spans: row0)

    let hasR = (usage.reasoningTokens ?? 0) > 0
    let hasCache = (usage.cachedPromptTokens ?? 0) > 0
    let lineDetail: TLine? = {
      guard hasR || hasCache else { return nil }
      var row1: [StyledSpan] = []
      if hasR {
        row1.append(uSpan(ScribePalette.usageLabel, "reasoning "))
        row1.append(uSpan(ScribePalette.usageReasoning, formatUsageInt(usage.reasoningTokens!)))
      }
      if hasR && hasCache {
        row1.append(uSpan(ScribePalette.usageMuted, sep))
      }
      if hasCache {
        row1.append(uSpan(ScribePalette.usageLabel, "cache "))
        row1.append(uSpan(ScribePalette.usageCache, formatUsageInt(usage.cachedPromptTokens!)))
      }
      return TLine(spans: row1)
    }()

    let lineSums = TLine(spans: [
      uSpan(ScribePalette.usageLabel, "turn Σ "),
      uSpan(ScribePalette.usageTurnSum, formatUsageInt(usage.turnTotal), bold: true),
      uSpan(ScribePalette.usageMuted, sep),
      uSpan(ScribePalette.usageLabel, "all Σ "),
      uSpan(ScribePalette.usageSessionSum, formatUsageInt(usage.sessionTotal), bold: true),
    ])

    var full: [TLine] = [line0]
    if let lineDetail {
      full.append(lineDetail)
    }
    full.append(lineSums)

    guard maxRows > 0 else { return [] }
    if full.count <= maxRows { return full }
    if maxRows == 1 { return [line0] }
    // maxRows == 2 and we have 3 logical lines: drop the middle (detail) band.
    if maxRows == 2, full.count == 3 {
      return [line0, lineSums]
    }
    return Array(full.prefix(maxRows))
  }

  private static func usageHUDCharCount(_ usage: UsageHUDSnapshot, maxRows: Int) -> Int {
    let ls = usageHUDLines(from: usage, maxRows: maxRows)
    return ls.map { $0.spans.reduce(0) { $0 + $1.text.count } }.max() ?? 0
  }

  private static func paintBannerKV(
    into grid: inout TerminalCellGrid,
    row: Int,
    cols: Int,
    maxWidth: Int,
    label: String,
    value: String
  ) {
    guard row >= 0, row < grid.rows else { return }
    let dk = ScribePalette.grayDark
    let lt = ScribePalette.grayLight
    let bg = ScribePalette.black
    let cap = min(max(0, maxWidth), cols)
    let maxValueChars = max(0, cap &- label.count)
    var v = value
    if v.count > maxValueChars {
      v = String(v.prefix(max(0, maxValueChars &- 1))) + "…"
    }
    let line = TLine(spans: [
      StyledSpan(fg: dk, bg: bg, bold: false, text: label),
      StyledSpan(fg: lt, bg: bg, bold: false, text: v),
    ])
    blit(line: line, into: &grid, column: 0, row: row, width: cap)
  }

  private static func paintUsageHUD(
    into grid: inout TerminalCellGrid,
    cols: Int,
    usage: UsageHUDSnapshot?,
    maxRows: Int
  ) {
    guard let usage, maxRows > 0 else { return }
    let lines = usageHUDLines(from: usage, maxRows: maxRows)
    for (row, line) in lines.enumerated() {
      guard row >= 0, row < grid.rows else { break }
      let w = line.spans.reduce(0) { $0 + $1.text.count }
      let startCol = max(0, cols &- w)
      blit(line: line, into: &grid, column: startCol, row: row, width: cols &- startCol)
    }
  }

  private static func fillInputBackground(
    into grid: inout TerminalCellGrid,
    startRow: Int,
    rowCount: Int,
    cols: Int,
    background: TerminalRGB
  ) {
    guard rowCount > 0 else { return }
    let endRow = min(grid.rows, startRow &+ rowCount)
    var r = max(0, startRow)
    while r < endRow {
      for c in 0..<min(cols, grid.cols) {
        grid[column: c, row: r] = TerminalCell(
          glyph: " ", foreground: ScribePalette.white, background: background, flags: [])
      }
      r &+= 1
    }
  }

  /// Paints the input stack: first row `you: `, continuation rows gutter-indented; caret on the last row.
  private static func paintInputRows(
    into grid: inout TerminalCellGrid,
    startRow: Int,
    cols: Int,
    textWidth: Int,
    visualLines: [String],
    rowCount: Int,
    llmWaitAnimationFrame: Int,
    showSpinner: Bool
  ) {
    let bg = ScribePalette.inputAreaBg
    let gutter = String(repeating: " ", count: min(inputGutterColumns, cols))
    var lineIdx = 0
    while lineIdx < rowCount {
      let row = startRow &+ lineIdx
      guard row >= 0, row < grid.rows else { break }
      var col = 0
      func paint(
        _ text: String,
        foreground: TerminalRGB,
        flags: TerminalCellFlags = []
      ) {
        for ch in text {
          guard col < cols else { return }
          grid[column: col, row: row] = TerminalCell(
            glyph: ch, foreground: foreground, background: bg, flags: flags)
          col += 1
        }
      }

      let onLastInputRow = lineIdx == rowCount &- 1

      if showSpinner, onLastInputRow {
        paint("scribe: ", foreground: ScribePalette.purple)
        let frames = llmWaitSpinner
        let ch = frames[llmWaitAnimationFrame % frames.count]
        paint(String(ch), foreground: ScribePalette.thinking)
        paint("▏", foreground: ScribePalette.white)
      } else if lineIdx == 0 {
        paint("you: ", foreground: ScribePalette.orange)
        if lineIdx < visualLines.count, textWidth > 0 {
          paint(String(visualLines[lineIdx].prefix(textWidth)), foreground: ScribePalette.white)
        }
        if onLastInputRow {
          paint("▏", foreground: ScribePalette.white)
        }
      } else {
        paint(gutter, foreground: ScribePalette.grayDim)
        if lineIdx < visualLines.count, textWidth > 0 {
          paint(String(visualLines[lineIdx].prefix(textWidth)), foreground: ScribePalette.white)
        }
        if onLastInputRow {
          paint("▏", foreground: ScribePalette.white)
        }
      }

      while col < cols {
        grid[column: col, row: row] = TerminalCell(
          glyph: " ", foreground: ScribePalette.white, background: bg, flags: [])
        col += 1
      }
      lineIdx &+= 1
    }
  }

  /// Paints the queued-tray strip that sits between the transcript and the input area:
  /// first row prefixed with `queued: ` (orange) plus the message in dimmed white;
  /// continuation rows align under the message with an 8-space gutter.
  private static func paintQueuedTrayRows(
    into grid: inout TerminalCellGrid,
    startRow: Int,
    cols: Int,
    textWidth: Int,
    visualLines: [String]
  ) {
    guard !visualLines.isEmpty else { return }
    let bg = ScribePalette.inputAreaBg
    let gutterText = String(repeating: " ", count: min(queuedTrayGutterColumns, cols))
    var lineIdx = 0
    while lineIdx < visualLines.count {
      let row = startRow &+ lineIdx
      guard row >= 0, row < grid.rows else { break }
      var col = 0
      func paint(
        _ text: String,
        foreground: TerminalRGB,
        flags: TerminalCellFlags = []
      ) {
        for ch in text {
          guard col < cols else { return }
          grid[column: col, row: row] = TerminalCell(
            glyph: ch, foreground: foreground, background: bg, flags: flags)
          col += 1
        }
      }

      if lineIdx == 0 {
        paint("queued: ", foreground: ScribePalette.orange)
      } else {
        paint(gutterText, foreground: ScribePalette.grayDim)
      }
      if textWidth > 0 {
        paint(String(visualLines[lineIdx].prefix(textWidth)), foreground: ScribePalette.grayLight)
      }

      while col < cols {
        grid[column: col, row: row] = TerminalCell(
          glyph: " ", foreground: ScribePalette.white, background: bg, flags: [])
        col += 1
      }
      lineIdx &+= 1
    }
  }

  private static func blit(line: TLine, into grid: inout TerminalCellGrid, column: Int, row: Int, width: Int) {
    guard row >= 0, row < grid.rows else { return }
    var x = column
    for span in line.spans {
      let flags: TerminalCellFlags = span.bold ? .bold : []
      for ch in span.text {
        guard x < column &+ width, x < grid.cols else { return }
        grid[column: x, row: row] = TerminalCell(
          glyph: ch, foreground: span.fg, background: span.bg, flags: flags)
        x &+= 1
      }
    }
  }
}

// MARK: - Host

/// Arrow / page keys mapped to transcript viewport motion (CSI, xterm-style).
private enum TranscriptScrollStep {
  case lineUp
  case lineDown
  case pageUp
  case pageDown
  /// ``ESC [ F`` (empty params): follow live tail / newest content.
  case snapToLiveBottom
  /// ``ESC [ H`` (empty params): jump to oldest buffered history in view.
  case snapToHistoryTop
}

/// Incremental word-wrap flatten of completed transcript lines (streaming only re-wraps the open tail).
private struct TranscriptFlattenCache {
  var wrapWidth: Int = -1
  var completedLogicalLines: Int = 0
  var completedFlat: [TLine] = []
}

@MainActor
private final class SlateChatHost {

  /// Xterm-compatible CSI final byte (`0x40`…`0x7E`): ends `\e[` parameter sequences incl. `…~` paste markers and `…u` kitty-style keys.
  /// Caller must require `accumulator.count >= 3` so `\e[` alone is not mistaken for complete CSI—the `[` byte (0x5B) sits in `0x40`…`0x7E`.
  private static func isCsiTerminator(_ byte: UInt8) -> Bool {
    byte >= 0x40 && byte <= 0x7E
  }

  private static let bracketPasteOpenSeq: ContiguousArray<UInt8> = [27, 91, 50, 48, 48, 126]
  private static let bracketPasteCloseSeq: ContiguousArray<UInt8> = [27, 91, 50, 48, 49, 126]

  /// Recognizes `\e[A` / `\e[B`, `\e[5~` / `\e[6~`, and bare `\e[H` / `\e[F` (cursor keys / paging / Home / End).
  private static func parseTranscriptScrollStep(fromCSI bytes: ContiguousArray<UInt8>) -> TranscriptScrollStep? {
    guard bytes.count >= 3, bytes[0] == 27, bytes[1] == 91 else { return nil }
    let terminator = bytes[bytes.count - 1]

    let paramRegion = bytes[2..<(bytes.count - 1)]
    guard let inner = String(bytes: paramRegion, encoding: .utf8) else { return nil }
    let ints = inner.split(separator: ";").compactMap { Int($0) }

    switch terminator {
    case UInt8(ascii: "A"):
      return .lineUp
    case UInt8(ascii: "B"):
      return .lineDown
    case UInt8(ascii: "H"):
      guard inner.isEmpty else { return nil }
      return .snapToHistoryTop
    case UInt8(ascii: "F"):
      guard inner.isEmpty else { return nil }
      return .snapToLiveBottom
    case UInt8(ascii: "~"):
      guard let k = ints.first else { return nil }
      if k == 5 { return .pageUp }
      if k == 6 { return .pageDown }
      return nil
    default:
      return nil
    }
  }

  private let configuration: AgentConfig
  private let client: Client
  private let systemPrompt: String
  private let resumeArchive: ChatSessionArchive?
  private let sessionPersistenceURL: URL
  private let sessionId: UUID
  private let sessionCreatedAt: Date
  private var inputBuffer = ""
  /// Index into the flattened transcript of the top row of the transcript viewport (used when ``followingLiveTranscript`` is false).
  private var transcriptFirstVisibleRow: Int = 0
  /// When true, the viewport follows the live tail (new tokens stay at the bottom). When false, ``transcriptFirstVisibleRow`` is fixed so streaming does not move the view.
  private var followingLiveTranscript: Bool = true
  private var flattenCache = TranscriptFlattenCache()
  /// Incomplete `\e`-led sequence (`\e[` CSI until terminator, or `\e` + immediate non-`[` char).
  private var escAccumulator: ContiguousArray<UInt8>?
  private var utf8Staging: ContiguousArray<UInt8> = []
  /// After a CR submit (`\r`), swallow the lone `\n` of a CRLF pair.
  private var swallowLfAfterCrSubmit = false
  private var bracketedPasteActive = false
  private var bracketCloseMatchPrefix = 0
  private var renderWake: ExternalWake?
  private var llmWaitAnimationFrame: Int = 0
  private var spinnerTask: Task<Void, Never>?
  private var coordinatorTask: Task<Void, Never>?
  private let modelInterruptFlag = ModelTurnInterruptFlag()
  /// Holds a user submission that arrived while the agent was busy. The text lives in the queued
  /// tray UI strip above the input; it is delivered to the coordinator when the user explicitly
  /// hits Enter again (interrupting the agent), recalls it with Ctrl+C, or when the current model
  /// turn finishes naturally.
  private var queuedSubmission: String? = nil
  /// Previous-render snapshot of `sink.modelTurnBusy()`, used to detect busy → idle transitions
  /// in `onEvent` and auto-flush a queued submission to the coordinator at that moment.
  private var lastObservedModelBusy: Bool = false
  /// Per-session logger threaded in from `Chat.run`; writes to `scribe-{uuid}.log`.
  /// All chat events emitted from this host use this logger and the structured
  /// `event=ns.name k=v k=v` format documented in ``docs/chat-input-behavior.md``.
  private let log: Logger

  init(
    configuration: AgentConfig,
    client: Client,
    systemPrompt: String,
    resumeArchive: ChatSessionArchive?,
    sessionPersistenceURL: URL,
    sessionId: UUID,
    sessionCreatedAt: Date,
    log: Logger
  ) {
    self.configuration = configuration
    self.client = client
    self.systemPrompt = systemPrompt
    self.resumeArchive = resumeArchive
    self.sessionPersistenceURL = sessionPersistenceURL
    self.sessionId = sessionId
    self.sessionCreatedAt = sessionCreatedAt
    self.log = log
  }

  deinit {
    spinnerTask?.cancel()
  }

  func run() async throws {
    let slate = try Slate()
    let sink = SlateTranscriptSink()
    let gate = UserLineGate()

    // Bracketed paste: pasted text (possibly multi-byte or multi-line) is wrapped so newlines aren’t mistaken for submits.
    try? FileHandle.standardOutput.write(contentsOf: Data("\u{001b}[?2004h".utf8))
    defer {
      try? FileHandle.standardOutput.write(contentsOf: Data("\u{001b}[?2004l".utf8))
    }

    // External wakes (every SSE chunk, every persist, every emitUsage) are coalesced at the
    // pump's default ~60 fps — i.e. at most one render per ~16 ms regardless of how busy the
    // streaming side is. Coupled with the async tty writer in `slate` (frames are submitted
    // to a background task instead of blocking the main actor on `write(2)`), this keeps the
    // main actor responsive to stdin even during heavy reasoning streams.
    //
    // The throttle pipeline can elide the *trailing* wake at the end of a fast burst — so
    // `markModelTurnRunning(false)` schedules a deferred follow-up render (see
    // ``SlateTranscriptSink/markModelTurnRunning``) that fires ~50 ms later, guaranteeing the
    // UI catches up to the new idle state instead of leaving the spinner hot until the next
    // key/resize.
    await slate.start(
      prepare: { [self] wake in
        sink.installWake(wake)
        self.renderWake = wake
        let resumeSnapshot = self.resumeArchive
        if let resumed = resumeSnapshot {
          do {
            try sink.replayPersistedConversation(resumed.messages)
          } catch {
            try? sink.printHarnessRunError(error)
          }
          self.flattenCache = TranscriptFlattenCache()
        }

        let persistURL = self.sessionPersistenceURL
        let cid = self.sessionId
        let created = self.sessionCreatedAt
        let modelSnapshot = configuration.agentModel
        let baseSnapshot = configuration.openAIBaseURL
        let persistLog = self.log
        let persist: @Sendable ([Components.Schemas.ChatMessage]) -> Void = { history in
          let cwd = FileManager.default.currentDirectoryPath
          do {
            try ChatSessionStore.save(
              ChatSessionArchive(
                id: cid,
                createdAt: created,
                updatedAt: Date(),
                cwd: cwd,
                model: modelSnapshot,
                baseURL: baseSnapshot,
                messages: history
              ),
              to: persistURL
            )
            persistLog.trace(
              """
              event=chat.persist.save \
              messages=\(history.count) \
              path=\(persistURL.path)
              """
            )
          } catch {
            persistLog.error(
              """
              event=chat.persist.fail \
              path=\(persistURL.path) \
              err="\(error.localizedDescription)"
              """
            )
          }
        }

        let interruptFlag = self.modelInterruptFlag
        let sessionLog = self.log
        self.coordinatorTask = Task {
          [configuration, client, systemPrompt, sink, gate, resumeSnapshot, persist, interruptFlag, sessionLog] in
          defer { sink.markCoordinatorFinished() }
          do {
            try await ScribeAgentCoordinator.runInteractive(
              configuration: configuration,
              client: client,
              systemPrompt: systemPrompt,
              sink: sink,
              readUserLine: {
                // Record the submission in scrollback exactly when the coordinator picks it up,
                // so messages held in the queued-tray (during a busy turn) appear in scrollback
                // only at the moment they're dispatched—not while they sit in the tray.
                guard let line = await gate.nextLine() else { return nil }
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                  sink.recordUserSubmission(trimmedVisible: trimmed)
                }
                return line
              },
              initialConversation: resumeSnapshot?.messages,
              onConversationPersist: persist,
              prepareModelTurnStart: { interruptFlag.clear() },
              shouldAbortTurn: { interruptFlag.peek() },
              log: sessionLog
            )
          } catch {
            try? sink.printHarnessRunError(error)
            sessionLog.error(
              """
              event=chat.coordinator.fail \
              err="\(String(describing: error))"
              """
            )
          }
        }
        self.spinnerTask?.cancel()
        self.spinnerTask = Task { [weak self] in
          while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(90))
            guard let self else { return }
            guard sink.modelTurnBusy() else { continue }
            self.llmWaitAnimationFrame &+= 1
            self.renderWake?.requestRender()
          }
        }
        wake.requestRender()
      },
      externalCoalesceMaxFramesPerSecond: 60,
      onEvent: { event in
        switch event {
        case .resize:
          slate.refreshWindowSize()
        case .external:
          break
        case .stdinBytes(let chunk):
          if sink.coordinatorFinished() { return .stop }
          if chunk.isEmpty {
            Task { await gate.complete(nil) }
            return .stop
          }
          for byte in chunk {
            if sink.coordinatorFinished() {
              Task { await gate.complete(nil) }
              return .stop
            }
            if self.handleKey(byte: byte, sink: sink, gate: gate, slate: slate) {
              Task { await gate.complete(nil) }
              return .stop
            }
          }
        }
        // Auto-flush a queued tray message when the agent finishes a turn naturally
        // (busy → idle transition with the queue non-empty): hand it to the gate so the
        // coordinator picks it up on its next `readUserLine`, and clear the tray.
        let nowBusy = sink.modelTurnBusy()
        if !nowBusy, self.lastObservedModelBusy, let queued = self.queuedSubmission {
          self.log.debug(
            """
            event=chat.queue.auto-flush \
            trigger=busy-to-idle \
            chars=\(queued.count)
            """
          )
          self.queuedSubmission = nil
          sink.setQueuedTrayText(nil)
          Task { await gate.complete(queued) }
        }
        self.lastObservedModelBusy = nowBusy

        let prepareStart = Date()
        let flatTranscript = self.syncFlattenedTranscript(sink: sink, slate: slate)
        let queuedTrayText = sink.queuedTrayTextSnapshot()
        let contentRows = SlateChatRenderer.transcriptContentRows(
          cols: slate.cols,
          rows: slate.rows,
          banner: sink.bannerSnapshot(),
          usage: sink.usageHUDSnapshot(),
          inputLine: self.inputBuffer,
          waitingForLLM: sink.modelTurnBusy(),
          queuedTrayText: queuedTrayText
        )
        let maxTailStart = max(0, flatTranscript.count &- contentRows)
        if self.followingLiveTranscript {
          self.transcriptFirstVisibleRow = maxTailStart
        } else {
          self.transcriptFirstVisibleRow = min(self.transcriptFirstVisibleRow, maxTailStart)
        }
        let transcriptTailStart = self.transcriptFirstVisibleRow
        let prepareMs = Int(Date().timeIntervalSince(prepareStart) * 1000)
        let submitStart = Date()
        slate.enscribe(
          grid: SlateChatRenderer.makeGrid(
            cols: slate.cols,
            rows: slate.rows,
            flattenedTranscript: flatTranscript,
            transcriptTailStart: transcriptTailStart,
            banner: sink.bannerSnapshot(),
            usage: sink.usageHUDSnapshot(),
            inputLine: self.inputBuffer,
            llmWaitAnimationFrame: self.llmWaitAnimationFrame,
            waitingForLLM: sink.modelTurnBusy(),
            queuedTrayText: queuedTrayText))
        // `slate.enscribe` builds the cell grid + encodes it + submits one frame to the
        // async tty writer. The actual `write(2)` happens off-actor, so a high `submit_ms`
        // here means encode/grid-build was expensive (transcript layout, grid blits) — *not*
        // tty drain. Splitting prepare/submit pinpoints which side any future regression
        // lives on.
        let submitMs = Int(Date().timeIntervalSince(submitStart) * 1000)
        let totalMs = prepareMs &+ submitMs
        if totalMs >= 50 {
          self.log.debug(
            """
            event=chat.render.slow \
            elapsed_ms=\(totalMs) \
            prepare_ms=\(prepareMs) \
            submit_ms=\(submitMs) \
            flat_rows=\(flatTranscript.count) \
            cols=\(slate.cols) \
            rows=\(slate.rows) \
            model_busy=\(nowBusy) \
            queue_chars=\(self.queuedSubmission?.count ?? 0) \
            buffer_chars=\(self.inputBuffer.count)
            """
          )
        }
        return sink.coordinatorFinished() ? .stop : .continue
      })

    spinnerTask?.cancel()
    spinnerTask = nil
    renderWake = nil

    coordinatorTask?.cancel()
    await gate.complete(nil)
  }

  /// Handles ``Enter`` in the input box. The behaviour is:
  ///
  /// - **Empty buffer + no queued tray message** → no-op.
  /// - **Empty buffer + queued tray message** → interrupt the in-flight model turn (if any)
  ///   and dispatch the queued message to the coordinator (records it in scrollback the moment
  ///   the coordinator picks it up).
  /// - **Non-empty buffer + agent idle** → dispatch immediately (no tray, no delay): the
  ///   "first message goes straight to the agent" case.
  /// - **Non-empty buffer + agent busy** → place the buffer text into the queued tray
  ///   (replacing any earlier queued text). The user can then either edit + Enter to refine,
  ///   Enter on an empty buffer to send-via-interrupt, or Ctrl+C to recall the queued message.
  private func submitUserLine(sink: SlateTranscriptSink, gate: UserLineGate) {
    swallowLfAfterCrSubmit = true
    followingLiveTranscript = true
    transcriptFirstVisibleRow = 0
    let submit = inputBuffer
    inputBuffer = ""
    utf8Staging.removeAll(keepingCapacity: true)
    let trimmed = submit.trimmingCharacters(in: .whitespacesAndNewlines)
    let busy = sink.modelTurnBusy()
    let newlines = submit.reduce(0) { $0 + ($1 == "\n" ? 1 : 0) }

    if trimmed.isEmpty {
      // Second-Enter idiom: send the queued tray message now (interrupting if needed).
      guard let queued = queuedSubmission else {
        log.debug(
          """
          event=chat.user.submit \
          kind=noop \
          reason=empty-buffer-no-queue \
          model_busy=\(busy)
          """
        )
        return
      }
      let queuedNewlines = queued.reduce(0) { $0 + ($1 == "\n" ? 1 : 0) }
      log.debug(
        """
        event=chat.user.submit \
        kind=interrupt-and-send \
        chars=\(queued.count) \
        newlines=\(queuedNewlines) \
        model_busy=\(busy)
        """
      )
      queuedSubmission = nil
      sink.setQueuedTrayText(nil)
      if busy {
        modelInterruptFlag.request()
      }
      Task { await gate.complete(queued) }
      renderWake?.requestRender()
      return
    }

    if busy {
      // Park in the queued tray and wait for either the user (Enter / Ctrl+C) or for the
      // current turn to finish (auto-flushed in `onEvent`).
      let replacing = queuedSubmission != nil
      log.debug(
        """
        event=chat.user.submit \
        kind=queue \
        chars=\(submit.count) \
        newlines=\(newlines) \
        replacing=\(replacing) \
        model_busy=true
        """
      )
      queuedSubmission = submit
      sink.setQueuedTrayText(submit)
      renderWake?.requestRender()
    } else {
      // Agent is idle; dispatch immediately. Scrollback recording happens in the readUserLine
      // wrapper at pickup time.
      log.debug(
        """
        event=chat.user.submit \
        kind=immediate \
        chars=\(submit.count) \
        newlines=\(newlines) \
        model_busy=false
        """
      )
      Task { await gate.complete(submit) }
    }
  }

  /// Recomputes word-wrapped transcript rows, reusing flatten work for completed lines across streaming frames.
  private func syncFlattenedTranscript(sink: SlateTranscriptSink, slate: Slate) -> [TLine] {
    let (completed, open) = sink.snapshotTranscriptForLayout()
    let width = slate.cols

    if width != flattenCache.wrapWidth {
      flattenCache = TranscriptFlattenCache()
      flattenCache.wrapWidth = width
      flattenCache.completedFlat = TranscriptLayout.flattenedRows(from: completed, width: width)
      flattenCache.completedLogicalLines = completed.count
    } else if completed.count < flattenCache.completedLogicalLines {
      flattenCache.completedFlat = TranscriptLayout.flattenedRows(from: completed, width: width)
      flattenCache.completedLogicalLines = completed.count
    } else if completed.count > flattenCache.completedLogicalLines {
      let start = flattenCache.completedLogicalLines
      if start < completed.count {
        let newSlice = completed[start...]
        flattenCache.completedFlat.append(
          contentsOf: TranscriptLayout.flattenedRows(from: Array(newSlice), width: width))
      }
      flattenCache.completedLogicalLines = completed.count
    }

    if let open {
      return flattenCache.completedFlat
        + TranscriptLayout.flattenedRows(from: [open], width: width)
    }
    return flattenCache.completedFlat
  }

  private func applyTranscriptScroll(
    _ step: TranscriptScrollStep,
    sink: SlateTranscriptSink,
    slate: Slate
  ) {
    let flat = syncFlattenedTranscript(sink: sink, slate: slate)
    let contentRows = SlateChatRenderer.transcriptContentRows(
      cols: slate.cols,
      rows: slate.rows,
      banner: sink.bannerSnapshot(),
      usage: sink.usageHUDSnapshot(),
      inputLine: inputBuffer,
      waitingForLLM: sink.modelTurnBusy(),
      queuedTrayText: sink.queuedTrayTextSnapshot()
    )
    let page = max(1, contentRows)
    let maxTailStart = max(0, flat.count &- contentRows)

    switch step {
    case .snapToLiveBottom:
      followingLiveTranscript = true
      transcriptFirstVisibleRow = maxTailStart
    case .snapToHistoryTop:
      followingLiveTranscript = false
      transcriptFirstVisibleRow = 0
    case .lineUp, .pageUp:
      let delta = step == .lineUp ? 1 : page
      let wasFollowing = followingLiveTranscript
      followingLiveTranscript = false
      if wasFollowing {
        transcriptFirstVisibleRow = max(0, maxTailStart &- delta)
      } else {
        transcriptFirstVisibleRow = max(0, transcriptFirstVisibleRow &- delta)
      }
    case .lineDown, .pageDown:
      let delta = step == .lineDown ? 1 : page
      transcriptFirstVisibleRow = min(transcriptFirstVisibleRow &+ delta, maxTailStart)
      if transcriptFirstVisibleRow >= maxTailStart {
        followingLiveTranscript = true
      }
    }
    renderWake?.requestRender()
  }

  /// Inserts a soft newline into the input buffer and emits a `chat.user.input.newline`
  /// log line tagged with the originating key sequence. This is the single recorded path for
  /// Shift+Enter / Alt+Enter / Ctrl+J behaviour so the source key can be traced from the log.
  private func insertNewlineIntoInput(source: String) {
    inputBuffer.append("\n")
    log.debug(
      """
      event=chat.user.input.newline \
      source=\(source) \
      buffer_chars=\(inputBuffer.count) \
      has_queue=\(queuedSubmission != nil)
      """
    )
  }

  /// Returns `true` if the enclosing app should terminate (interrupt / EOF semantics).
  private func handleKey(byte: UInt8, sink: SlateTranscriptSink, gate: UserLineGate, slate: Slate) -> Bool {
    if byte == 3 {
      // Ctrl+C is a three-step ladder so the user can stage their reaction:
      //   1. With a queued tray message: pull it back into the input buffer for editing.
      //      The agent keeps running — this press only recalls the queued text.
      //   2. With no queue and an in-flight turn: interrupt the agent.
      //   3. With no queue and an idle prompt: exit the chat.
      let busy = sink.modelTurnBusy()
      if let queued = queuedSubmission {
        log.debug(
          """
          event=chat.user.ctrl-c \
          action=recall-queue \
          queue_chars=\(queued.count) \
          model_busy=\(busy)
          """
        )
        queuedSubmission = nil
        sink.setQueuedTrayText(nil)
        inputBuffer = queued
        utf8Staging.removeAll(keepingCapacity: true)
        renderWake?.requestRender()
        return false
      }
      if busy {
        log.debug(
          """
          event=chat.user.ctrl-c \
          action=interrupt-agent \
          model_busy=true
          """
        )
        modelInterruptFlag.request()
        renderWake?.requestRender()
        return false
      }
      log.debug(
        """
        event=chat.user.ctrl-c \
        action=exit \
        model_busy=false
        """
      )
      return true
    }
    if byte == 4 {
      log.debug("event=chat.user.ctrl-d action=exit")
      return true
    }

    if bracketedPasteActive {
      ingestBracketPasteByte(byte)
      return false
    }

    if var seq = escAccumulator {
      seq.append(byte)
      if seq.count >= 2, seq.first == 27, seq[1] != 91 {
        // `\e` + non-CSI: historically Option/Alt+Return sent ESC then CR/LF.
        escAccumulator = nil
        if byte == 10 || byte == 13 {
          insertNewlineIntoInput(source: "esc-prefix-cr-or-lf")
        } else {
          ingestUtf8Continuation(byte)
        }
        swallowLfAfterCrSubmit = false
        return false
      }
      escAccumulator = seq
      // Need at least `\e[<final>` — the `[` byte (0x5B) is in the terminator range (`0x40`…`0x7E`)
      // but is part of CSI's two-byte introducer, not the final parameter byte.
      if seq.count >= 3, seq[0] == 27, seq[1] == 91, let last = seq.last {
        if Self.isCsiTerminator(last) {
          escAccumulator = nil
          swallowLfAfterCrSubmit = false
          if let scroll = Self.parseTranscriptScrollStep(fromCSI: seq) {
            applyTranscriptScroll(scroll, sink: sink, slate: slate)
            return false
          }
          handleTerminatedCSI(seq, sink: sink, gate: gate)
          return false
        }
      }
      return false
    }

    if byte == 27 {
      escAccumulator = [27]
      return false
    }

    if byte == 10, swallowLfAfterCrSubmit {
      swallowLfAfterCrSubmit = false
      return false
    }
    if byte != 10 {
      swallowLfAfterCrSubmit = false
    }

    switch byte {
    case 13:
      submitUserLine(sink: sink, gate: gate)
    case 10:
      // Bare LF without a preceding CR — emitted by some terminals for Shift+Enter / Ctrl+J.
      insertNewlineIntoInput(source: "raw-lf")
    case 8, 127:
      removeLastLogicalCharacterFromInput()
    default:
      ingestUtf8Continuation(byte)
    }

    return false
  }

  /// Drop the last grapheme from the editable line (including staged UTF‑8 tails).
  private func removeLastLogicalCharacterFromInput() {
    guard !utf8Staging.isEmpty else {
      guard !inputBuffer.isEmpty else { return }
      inputBuffer.removeLast()
      return
    }

    utf8Staging.removeLast()
    while utf8Staging.count > 32 {
      utf8Staging.removeFirst()
      inputBuffer.unicodeScalars.append("\u{FFFD}")
    }

    while !utf8Staging.isEmpty, String(bytes: utf8Staging, encoding: .utf8) == nil {
      utf8Staging.removeLast()
    }
    collapseUtfStagingToBuffer()
  }

  private func ingestUtf8Continuation(_ byte: UInt8) {
    utf8Staging.append(byte)
    collapseUtfStagingToBuffer()

    guard utf8Staging.count > 8 else { return }
    utf8Staging.removeFirst()
    inputBuffer.unicodeScalars.append("\u{FFFD}")
    collapseUtfStagingToBuffer()
  }

  /// Moves complete UTF‑8 prefixes from staging into ``inputBuffer`` (leaves leftover bytes staged).
  private func collapseUtfStagingToBuffer() {
    while String(bytes: utf8Staging, encoding: .utf8) != nil, !utf8Staging.isEmpty {
      let decoded = utf8Staging
      utf8Staging.removeAll(keepingCapacity: true)
      guard let text = String(bytes: decoded, encoding: .utf8) else { return }
      for ch in text {
        switch ch {
        case Character(UnicodeScalar(0)): continue
        case "\u{001b}", "\u{007F}", "\u{0008}":
          continue
        default:
          inputBuffer.append(ch)
        }
      }
    }
  }

  /// Bracketed paste body (`\e[200~\` … `\e[201~`): literals only; close sequence is peeled off separately.
  private func ingestBracketPasteLiteral(_ byte: UInt8) {
    ingestUtf8Continuation(byte)
  }

  /// Detects `\e[201~` terminator while emitting every other byte as pasted text (including LF/Tab).
  private func ingestBracketPasteByte(_ byte: UInt8) {
    func flushCloseFalseStart() {
      for idx in 0..<bracketCloseMatchPrefix {
        ingestBracketPasteLiteral(Self.bracketPasteCloseSeq[idx])
      }
      bracketCloseMatchPrefix = 0
    }

    if byte == Self.bracketPasteCloseSeq[bracketCloseMatchPrefix] {
      bracketCloseMatchPrefix += 1
      if bracketCloseMatchPrefix == Self.bracketPasteCloseSeq.count {
        bracketCloseMatchPrefix = 0
        bracketedPasteActive = false
        collapseUtfStagingToBuffer()
        log.debug(
          """
          event=chat.user.input.paste-end \
          buffer_chars=\(inputBuffer.count)
          """
        )
      }
      return
    }

    if bracketCloseMatchPrefix > 0 {
      flushCloseFalseStart()
      ingestBracketPasteByte(byte)
      return
    }

    ingestBracketPasteLiteral(byte)
  }

  private func handleTerminatedCSI(
    _ bytes: ContiguousArray<UInt8>,
    sink _: SlateTranscriptSink,
    gate _: UserLineGate
  ) {
    if bytes.elementsEqual(Self.bracketPasteOpenSeq) {
      utf8Staging.removeAll(keepingCapacity: true)
      bracketedPasteActive = true
      bracketCloseMatchPrefix = 0
      log.debug(
        """
        event=chat.user.input.paste-begin \
        buffer_chars=\(inputBuffer.count)
        """
      )
      return
    }

    guard bytes.count >= 3, bytes[0] == 27, bytes[1] == 91 else { return }
    let terminator = bytes[bytes.count - 1]

    let paramRegion = bytes[2..<(bytes.count - 1)]
    guard let inner = String(bytes: paramRegion, encoding: .utf8) else { return }
    let ints = inner.split(separator: ";").compactMap { Int($0) }

    let csiSource: String
    switch terminator {
    case UInt8(ascii: "u"):
      // CSI u — plain Enter is `\r`. Non-zero modifier = soft newline (bitmask Shift=1, Alt=2, …).
      guard let key = ints.first, key == 13 else { return }
      guard ints.count >= 2, ints[1] != 0 else { return }
      csiSource = "csi-u-modified-enter mod=\(ints[1])"

    case UInt8(ascii: "~"):
      // Bracket paste open/close handled above; bracketed paste uses 200~/201~ digits.
      // xterm-style modified keys: `CSI 27 ; <modifier> ; 13 ~` (Shift+Enter often `27;2;13~`).
      if ints.count >= 3, ints[0] == 27, ints[2] == 13, ints[1] != 0 {
        csiSource = "csi-tilde-xterm-modified-enter mod=\(ints[1])"
        break
      }
      // Alternate `CSI 13 ; <modifier> ~` forms.
      if ints.count >= 2, ints[0] == 13, ints[1] != 0 {
        csiSource = "csi-tilde-modified-enter mod=\(ints[1])"
        break
      }
      return

    default:
      return
    }

    insertNewlineIntoInput(source: csiSource)
    swallowLfAfterCrSubmit = false
  }
}

enum ChatTerminalError: Error, LocalizedError {
  /// Stdin is not a TTY (pipes, redirection, CI, etc.).
  case notATerminal
  /// Slate declined or could not use the alternate-screen UI.
  case slateNotInteractive

  var errorDescription: String? {
    switch self {
    case .notATerminal:
      return "`scribe chat` requires an interactive terminal (stdin must be a TTY)."
    case .slateNotInteractive:
      return "`scribe chat` requires a fully interactive terminal; the fullscreen UI could not attach."
    }
  }
}

enum SlateChat {
  /// Runs the chat session using the Slate alternate-screen UI; fails if stdin is not a TTY or Slate cannot attach.
  ///
  /// When ``resumeArchive`` is `nil`, ``sessionPersistenceURL`` must end with `{uuid}.json` (see ``ChatSessionStore/fileURL(sessionId:configuration:)``).
  ///
  /// - Parameters:
  ///   - resumeArchive: If set, restores model context and redraws approximate transcript (`sessionPersistenceURL` should point at that archive).
  ///   - sessionId: UUID identifying this Scribe invocation (matches the `{uuid}.json` archive
  ///     stem and the `scribe-{uuid}.log` file the `log` parameter writes to).
  ///   - log: Per-session logger created in `Chat.run` via ``AgentConfig/makeSessionLogger(sessionId:)``.
  ///     All chat events for this invocation funnel into this single `Logger`; we no longer emit
  ///     to a separate diagnostics file.
  static func runFullscreen(
    configuration: AgentConfig,
    client: Client,
    systemPrompt: String,
    resumeArchive: ChatSessionArchive? = nil,
    sessionPersistenceURL: URL,
    sessionId: UUID,
    log: Logger
  ) async throws {
    guard isatty(STDIN_FILENO) != 0 else {
      log.error("event=chat.session.fail reason=stdin-not-tty")
      throw ChatTerminalError.notATerminal
    }
    log.debug(
      """
      event=chat.fullscreen.attach \
      session_file=\(sessionPersistenceURL.lastPathComponent)
      """
    )
    try await Task { @MainActor () throws -> Void in
      let sessionCreatedAt = resumeArchive?.createdAt ?? Date()
      let host = SlateChatHost(
        configuration: configuration,
        client: client,
        systemPrompt: systemPrompt,
        resumeArchive: resumeArchive,
        sessionPersistenceURL: sessionPersistenceURL,
        sessionId: sessionId,
        sessionCreatedAt: sessionCreatedAt,
        log: log
      )
      do {
        try await host.run()
      } catch Slate.InstallationError.notInteractiveTerminal {
        log.error(
          "event=chat.fullscreen.fail reason=slate-not-interactive"
        )
        throw ChatTerminalError.slateNotInteractive
      }
    }.value
  }
}
