import Foundation
import ScribeCore
import SlateCore

// MARK: - TranscriptController

/// Builds a transcript from `TranscriptEvent` values — pure state machine,
/// testable without a terminal or Slate.
///
/// Extracted from `SlateChatHost.handleTranscriptEvent()`.  Owns the
/// transcript lines (completed + open streaming line) and updates them
/// in response to each event.
public struct TranscriptController: Sendable {

  // MARK: - Public state

  /// Completed transcript lines (user messages, finalized assistant turns, tool output).
  public private(set) var completedLines: [TLine] = []

  /// Open line being built during streaming (nil when idle).
  public private(set) var streamingOpenLine: TLine? = nil

  /// Raw accumulated text for the current streaming section.
  public private(set) var streamingOpenLineRaw: String = ""

  /// Bumped when transcript structure changes (for cache invalidation).
  public private(set) var generation: Int = 0

  // MARK: - Private state

  private var streamingSectionStartLineIndex: Int? = nil
  private var currentStreamingSection: AssistantStreamSection = .answer

  // MARK: - Init

  public init() {}

  // MARK: - Apply event

  /// Apply a `TranscriptEvent`, updating the transcript state.
  /// Returns `true` when the event changed the transcript (useful for
  /// callers that want to know when to re-render).
  @discardableResult
  public mutating func apply(
    _ event: TranscriptEvent,
    theme: CLITheme,
    renderer: MarkdownRenderer
  ) -> Bool {
    switch event {
    case .enterAssistantSection(let section, let previous):
      applyEnterAssistantSection(section, previous: previous, theme: theme)

    case .appendAssistantText(let section, let text):
      applyAppendAssistantText(section, text: text, theme: theme, renderer: renderer)

    case .finalizeAssistantStream:
      applyFinalizeAssistantStream(theme: theme, renderer: renderer)

    case .emptyAssistantTurn:
      applyEmptyAssistantTurn(theme: theme)

    case .usage:
      // No transcript impact — usage is tracked separately.
      return false

    case .blankLine:
      applyBlankLine()

    case .toolRoundHeader(let round, let toolNames):
      applyToolRoundHeader(round: round, toolNames: toolNames, theme: theme)

    case .toolInvocation(let name, let arguments, let output):
      applyToolInvocation(name: name, arguments: arguments, output: output, theme: theme)

    case .skippedUnreadableStreamLine:
      applySkippedUnreadableStreamLine(theme: theme)

    case .harnessError(let error):
      applyHarnessError(error, theme: theme)

    case .turnInterrupted:
      applyTurnInterrupted(theme: theme)

    case .userSubmitted(let text):
      applyUserSubmitted(text, theme: theme)

    case .turnComplete:
      applyTurnComplete()
    }
    return true
  }

  // MARK: - Bulk apply

  /// Apply a sequence of events, returning a snapshot after each one
  /// (useful for tests that want per-event history).
  public mutating func applyAll(
    _ events: some Sequence<TranscriptEvent>,
    theme: CLITheme,
    renderer: MarkdownRenderer
  ) -> [TranscriptSnapshot] {
    var history: [TranscriptSnapshot] = []
    for event in events {
      apply(event, theme: theme, renderer: renderer)
      history.append(TranscriptSnapshot(
        event: event,
        completedLines: completedLines,
        streamingOpenLine: streamingOpenLine
      ))
    }
    return history
  }

  // MARK: - Event handlers

  private mutating func applyEnterAssistantSection(
    _ section: AssistantStreamSection,
    previous: AssistantStreamSection?,
    theme: CLITheme
  ) {
    // Finalize previous open line if any.
    if let open = streamingOpenLine {
      completedLines.append(open)
      streamingOpenLine = nil
    }
    if previous != nil {
      if previous == .reasoning && section == .answer {
        completedLines.append(TLine(spans: []))
      }
    } else {
      if let last = completedLines.last, isUserSubmissionLine(last, theme: theme) {
        completedLines.append(TLine(spans: []))
      }
    }
    let header = TLine(
      spans: [
        StyledSpan(
          fg: theme.scribePrefix, bg: theme.background, bold: false, text: "scribe:")
      ])
    completedLines.append(header)
    switch section {
    case .reasoning:
      completedLines.append(
        TLine(
          spans: [
            StyledSpan(
              fg: theme.sectionLabel, bg: theme.background, bold: false,
              text: "  · reasoning")
          ]))
    case .answer:
      completedLines.append(
        TLine(
          spans: [
            StyledSpan(
              fg: theme.sectionLabel, bg: theme.background, bold: false,
              text: "  · answer")
          ]))
    }
    streamingOpenLine = TLine(spans: [])
    streamingOpenLineRaw = ""
    streamingSectionStartLineIndex = completedLines.count
    currentStreamingSection = section
    generation &+= 1
  }

  private mutating func applyAppendAssistantText(
    _ section: AssistantStreamSection,
    text: String,
    theme: CLITheme,
    renderer: MarkdownRenderer
  ) {
    if streamingOpenLine == nil {
      streamingOpenLine = TLine(spans: [])
      streamingOpenLineRaw = ""
    }
    streamingOpenLineRaw += text
    currentStreamingSection = section

    // Render the tail of the accumulated text (streaming path).
    let st = theme.style(for: section)
    let maxVisibleLogicalLines = 200
    let tailText: String = {
      let allLines = streamingOpenLineRaw.split(
        separator: "\n", omittingEmptySubsequences: false)
      guard allLines.count > maxVisibleLogicalLines else {
        return streamingOpenLineRaw
      }
      return allLines.suffix(maxVisibleLogicalLines).joined(separator: "\n")
    }()

    let rendered = renderer.renderStreaming(
      text: tailText,
      baseFG: st.fg,
      baseBold: st.bold,
      theme: section == .reasoning ? .grayscale : theme.markdown
    )
    if let startIdx = streamingSectionStartLineIndex {
      let removeCount = max(0, completedLines.count - startIdx)
      if removeCount > 0 {
        completedLines.removeLast(removeCount)
        generation &+= 1
      }
    }
    if rendered.isEmpty {
      streamingOpenLine = TLine(spans: [])
    } else {
      completedLines.append(contentsOf: rendered.dropLast())
      streamingOpenLine = rendered.last!
    }
    generation &+= 1
  }

  private mutating func applyFinalizeAssistantStream(
    theme: CLITheme,
    renderer: MarkdownRenderer
  ) {
    // Re-render accumulated text with full block-level markdown.
    if streamingSectionStartLineIndex != nil {
      let section = currentStreamingSection
      let st = theme.style(for: section)
      let mdTheme = section == .reasoning ? MarkdownTheme.grayscale : theme.markdown
      let fullRender = renderer.render(
        text: streamingOpenLineRaw,
        baseFG: st.fg,
        baseBold: st.bold,
        theme: mdTheme
      )
      if let startIdx = streamingSectionStartLineIndex {
        let removeCount = max(0, completedLines.count - startIdx)
        if removeCount > 0 {
          completedLines.removeLast(removeCount)
          generation &+= 1
        }
        if fullRender.isEmpty {
          streamingOpenLine = TLine(spans: [])
        } else {
          completedLines.append(contentsOf: fullRender.dropLast())
          streamingOpenLine = fullRender.last!
        }
      }
    }
    if let open = streamingOpenLine {
      completedLines.append(open)
      streamingOpenLine = nil
    }
    streamingOpenLineRaw = ""
    streamingSectionStartLineIndex = nil
    generation &+= 1
  }

  private mutating func applyEmptyAssistantTurn(theme: CLITheme) {
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
    completedLines.append(lineA)
    completedLines.append(lineB)
    generation &+= 1
  }

  private mutating func applyBlankLine() {
    completedLines.append(TLine(spans: []))
    generation &+= 1
  }

  private mutating func applyToolRoundHeader(
    round: Int,
    toolNames: [String],
    theme: CLITheme
  ) {
    let names = toolNames.joined(separator: ", ")
    let line = TLine(spans: [
      StyledSpan(
        fg: theme.toolRoundHeader, bg: theme.background, bold: true,
        text: "tool round \(round) "),
      StyledSpan(
        fg: theme.toolNames, bg: theme.background, bold: false, text: names),
    ])
    completedLines.append(line)
    generation &+= 1
  }

  private mutating func applyToolInvocation(
    name: String,
    arguments: String,
    output: String,
    theme: CLITheme
  ) {
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
    completedLines.append(TLine(spans: spans))
    for ol in outputLines {
      completedLines.append(
        TLine(
          spans: [
            StyledSpan(
              fg: theme.toolOutput, bg: theme.background, bold: false,
              text: "  \(ol)")
          ]))
    }
    generation &+= 1
  }

  private mutating func applySkippedUnreadableStreamLine(theme: CLITheme) {
    completedLines.append(
      TLine(
        spans: [
          StyledSpan(
            fg: theme.skippedStreamLine, bg: theme.background, bold: false,
            text: "(skipped one stream line: not valid completion JSON)")
        ]))
    generation &+= 1
  }

  private mutating func applyHarnessError(_ error: ScribeError, theme: CLITheme) {
    completedLines.append(
      TLine(
        spans: [
          StyledSpan(
            fg: theme.errorFG, bg: theme.background, bold: false,
            text: "error: \(error.errorDescription ?? String(describing: error))")
        ]))
    generation &+= 1
  }

  private mutating func applyTurnInterrupted(theme: CLITheme) {
    completedLines.append(
      TLine(
        spans: [
          StyledSpan(
            fg: theme.interruptedFG, bg: theme.background, bold: false,
            text: "(interrupted)")
        ]))
    streamingOpenLine = nil
    streamingOpenLineRaw = ""
    streamingSectionStartLineIndex = nil
    generation &+= 1
  }

  private mutating func applyUserSubmitted(_ text: String, theme: CLITheme) {
    guard !text.isEmpty else { return }
    let logicalLines =
      text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    completedLines.append(
      TLine(
        spans: [
          StyledSpan(
            fg: theme.userPrefix, bg: theme.background, bold: false,
            text: "you:")
        ]))
    for row in logicalLines {
      if row.isEmpty {
        completedLines.append(TLine(spans: []))
        continue
      }
      completedLines.append(
        TLine(
          spans: [
            StyledSpan(
              fg: theme.userBody, bg: theme.background, bold: false,
              text: "  \(row)")
          ]))
    }
    generation &+= 1
  }

  private mutating func applyTurnComplete() {
    // Finalize any dangling streaming state (defensive).
    if let open = streamingOpenLine {
      completedLines.append(open)
    }
    streamingOpenLine = nil
    streamingOpenLineRaw = ""
    streamingSectionStartLineIndex = nil
    generation &+= 1
  }

  // MARK: - Helpers

  private func isUserSubmissionLine(_ line: TLine, theme: CLITheme) -> Bool {
    guard line.spans.count == 1 else { return false }
    let s = line.spans[0]
    return !s.bold
      && s.fg == theme.userPrefix
      && s.bg == theme.background
      && s.text == "you:"
  }
}

// MARK: - TranscriptSnapshot

/// A point-in-time snapshot of transcript state.
public struct TranscriptSnapshot: Sendable {
  /// The event that produced this snapshot.
  public var event: TranscriptEvent
  /// Completed transcript lines after the event.
  public var completedLines: [TLine]
  /// The open streaming line, if any.
  public var streamingOpenLine: TLine?

  public init(
    event: TranscriptEvent,
    completedLines: [TLine],
    streamingOpenLine: TLine?
  ) {
    self.event = event
    self.completedLines = completedLines
    self.streamingOpenLine = streamingOpenLine
  }
}
