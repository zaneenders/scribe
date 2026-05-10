import Foundation
import ScribeCore
import ScribeLLM

// MARK: - TranscriptController

/// Owns the transcript line buffer and streaming state.
/// Pure value type — Sendable, no MainActor, no Slate dependency.
struct TranscriptController: Sendable {
  /// Completed transcript lines (user messages, finalized assistant turns,
  /// tool output).
  private(set) var completedLines: [TLine] = []

  /// Open line being built during streaming (nil when idle).
  private(set) var streamingOpenLine: TLine? = nil

  /// Accumulated raw text of the current streaming section (for finalize).
  private(set) var streamingRawText: String = ""

  /// Index into `completedLines` where the current streaming section started.
  /// Used to replace the streaming tail on each chunk.
  private(set) var streamingSectionStartLineIndex: Int? = nil

  /// Which section is currently streaming (.answer / .reasoning).
  private(set) var currentStreamingSection: AssistantStreamSection = .answer

  /// Bumped when transcript structure changes (for FlattenCache invalidation).
  private(set) var generation: Int = 0

  // MARK: - Event application

  /// Apply a TranscriptEvent, mutating state and returning whether a render
  /// is needed.  The `theme` and `renderer` are injected so this stays pure
  /// (no global dependencies).
  ///
  /// - Parameter liveRender: When `false`, `appendAssistantText` still
  ///   accumulates raw text but skips the per-chunk render pass (used when
  ///   the user has scrolled up and the streaming tail isn't visible).
  mutating func apply(
    _ event: TranscriptEvent,
    theme: CLITheme,
    renderer: MarkdownRenderer,
    liveRender: Bool = true
  ) -> ApplyResult {
    switch event {
    case .enterAssistantSection(let section, let previous):
      return applyEnterAssistantSection(section: section, previous: previous, theme: theme)

    case .appendAssistantText(let section, let text):
      return applyAppendAssistantText(
        section: section, text: text, theme: theme, renderer: renderer,
        liveRender: liveRender)

    case .finalizeAssistantStream:
      return applyFinalizeAssistantStream(theme: theme, renderer: renderer)

    case .emptyAssistantTurn:
      return applyEmptyAssistantTurn(theme: theme)

    case .usage:
      // Usage is handled separately by the host — no transcript mutation.
      return ApplyResult(needsRender: false)

    case .blankLine:
      return applyBlankLine()

    case .toolRoundHeader(let round, let toolNames):
      return applyToolRoundHeader(round: round, toolNames: toolNames, theme: theme)

    case .toolInvocation(let name, let arguments, let output):
      return applyToolInvocation(name: name, arguments: arguments, output: output, theme: theme)

    case .skippedUnreadableStreamLine:
      return applySkippedUnreadableStreamLine(theme: theme)

    case .harnessError(let error):
      return applyHarnessError(error, theme: theme)

    case .turnInterrupted:
      return applyTurnInterrupted(theme: theme)

    case .userSubmitted(let text):
      return applyUserSubmitted(text, theme: theme)

    case .turnComplete(let referenceMessages):
      return applyTurnComplete(
        referenceMessages: referenceMessages, theme: theme, renderer: renderer)
    }
  }

  // MARK: - Queries

  /// True if the last completed line (if any) is a user-submission line.
  func isLastLineUserSubmission() -> Bool {
    guard let last = completedLines.last, last.spans.count == 1 else { return false }
    let s = last.spans[0]
    // Match the same criteria as the host helper: non-bold, userPrefix fg,
    // background bg, text "you:".
    return !s.bold && s.text == "you:"
  }

  // MARK: - Bulk operations

  /// Replace all completed lines (used for resume/replay) and reset streaming state.
  mutating func resetCompletedLines(_ lines: [TLine]) {
    completedLines = lines
    streamingOpenLine = nil
    streamingRawText = ""
    streamingSectionStartLineIndex = nil
    currentStreamingSection = .answer
    generation &+= 1
  }

  // MARK: - Per-event implementations

  private mutating func applyEnterAssistantSection(
    section: AssistantStreamSection,
    previous: AssistantStreamSection?,
    theme: CLITheme
  ) -> ApplyResult {
    // Finalize previous open line if any.
    if let open = streamingOpenLine {
      completedLines.append(open)
      streamingOpenLine = nil
      generation &+= 1
    }
    if let previous {
      if previous == .reasoning && section == .answer {
        completedLines.append(TLine(spans: []))
        generation &+= 1
      }
    } else {
      if isLastLineUserSubmission() {
        completedLines.append(TLine(spans: []))
        generation &+= 1
      }
    }
    let header = TLine(
      spans: [
        StyledSpan(
          fg: theme.scribePrefix, bg: theme.background, bold: false, text: "scribe:")
      ])
    completedLines.append(header)
    generation &+= 1
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
    generation &+= 1
    streamingOpenLine = TLine(spans: [])
    streamingRawText = ""
    streamingSectionStartLineIndex = completedLines.count
    currentStreamingSection = section
    return ApplyResult(needsRender: true)
  }

  private mutating func applyAppendAssistantText(
    section: AssistantStreamSection,
    text: String,
    theme: CLITheme,
    renderer: MarkdownRenderer,
    liveRender: Bool
  ) -> ApplyResult {
    if streamingOpenLine == nil {
      streamingOpenLine = TLine(spans: [])
      streamingRawText = ""
    }
    streamingRawText += text
    currentStreamingSection = section

    guard liveRender else { return ApplyResult(needsRender: false) }

    let st = theme.style(for: section)

    // Only render the visible tail during streaming — the full accumulated
    // text is re-parsed with block-level markdown at finalize anyway.
    // Keeps per-chunk work bounded to O(screen) instead of O(total-response).
    let maxVisibleLogicalLines = 200  // generous: 2–4× a typical terminal
    let tailText: String = {
      let allLines = streamingRawText.split(
        separator: "\n", omittingEmptySubsequences: false)
      guard allLines.count > maxVisibleLogicalLines else {
        return streamingRawText
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
      generation &+= 1
    }
    return ApplyResult(needsRender: true)
  }

  private mutating func applyFinalizeAssistantStream(
    theme: CLITheme,
    renderer: MarkdownRenderer
  ) -> ApplyResult {
    // Re-render accumulated text with full block-level markdown.
    if streamingSectionStartLineIndex != nil {
      let section = currentStreamingSection
      let st = theme.style(for: section)
      let mdTheme = section == .reasoning ? MarkdownTheme.grayscale : theme.markdown
      let fullRender = renderer.render(
        text: streamingRawText,
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
          generation &+= 1
        }
      }
    }
    if let open = streamingOpenLine {
      completedLines.append(open)
      streamingOpenLine = nil
      generation &+= 1
    }
    streamingRawText = ""
    streamingSectionStartLineIndex = nil
    return ApplyResult(needsRender: true)
  }

  private mutating func applyEmptyAssistantTurn(theme: CLITheme) -> ApplyResult {
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
    return ApplyResult(needsRender: true)
  }

  private mutating func applyBlankLine() -> ApplyResult {
    completedLines.append(TLine(spans: []))
    generation &+= 1
    return ApplyResult(needsRender: true)
  }

  private mutating func applyToolRoundHeader(
    round: Int, toolNames: [String], theme: CLITheme
  ) -> ApplyResult {
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
    return ApplyResult(needsRender: true)
  }

  private mutating func applyToolInvocation(
    name: String, arguments: String, output: String, theme: CLITheme
  ) -> ApplyResult {
    let argSummary = ToolInvocationFormatting.argumentSummary(
      name: name, argumentsJSON: arguments)
    let outputLines = ToolInvocationFormatting.outputLines(
      name: name, jsonOutput: output)
    var spans: [StyledSpan] = [
      StyledSpan(
        fg: theme.toolInvocation, bg: theme.background, bold: false, text: "▶ \(name)")
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
    return ApplyResult(needsRender: true)
  }

  private mutating func applySkippedUnreadableStreamLine(theme: CLITheme) -> ApplyResult {
    completedLines.append(
      TLine(
        spans: [
          StyledSpan(
            fg: theme.skippedStreamLine, bg: theme.background, bold: false,
            text: "(skipped one stream line: not valid completion JSON)")
        ]))
    generation &+= 1
    return ApplyResult(needsRender: true)
  }

  private mutating func applyHarnessError(_ error: ScribeError, theme: CLITheme) -> ApplyResult {
    completedLines.append(
      TLine(
        spans: [
          StyledSpan(
            fg: theme.errorFG, bg: theme.background, bold: false,
            text: "error: \(error.errorDescription ?? String(describing: error))")
        ]))
    generation &+= 1
    return ApplyResult(needsRender: true)
  }

  private mutating func applyTurnInterrupted(theme: CLITheme) -> ApplyResult {
    completedLines.append(
      TLine(
        spans: [
          StyledSpan(
            fg: theme.interruptedFG, bg: theme.background, bold: false,
            text: "(interrupted)")
        ]))
    streamingOpenLine = nil
    streamingRawText = ""
    streamingSectionStartLineIndex = nil
    generation &+= 1
    return ApplyResult(needsRender: true)
  }

  private mutating func applyUserSubmitted(_ text: String, theme: CLITheme) -> ApplyResult {
    guard !text.isEmpty else { return ApplyResult(needsRender: false) }
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
    return ApplyResult(needsRender: true)
  }

  private mutating func applyTurnComplete(
    referenceMessages: [Components.Schemas.ChatMessage],
    theme: CLITheme,
    renderer: MarkdownRenderer
  ) -> ApplyResult {
    // Finalize any dangling streaming state (defensive — should already be done).
    if let open = streamingOpenLine {
      completedLines.append(open)
      generation &+= 1
    }
    streamingOpenLine = nil
    streamingRawText = ""
    streamingSectionStartLineIndex = nil

    // Compare streaming render against batch render for drift detection.
    let batchLines = renderMessagesToTranscript(
      referenceMessages, theme: theme, renderer: renderer)
    let drift: String? = {
      guard completedLines != batchLines else { return nil }
      let sc = completedLines.count
      let bc = batchLines.count
      var detail = "streaming_count=\(sc) batch_count=\(bc)"
      let maxCount = max(sc, bc)
      var diffs: [String] = []
      for idx in 0..<maxCount {
        let sLine = idx < sc ? completedLines[idx] : nil
        let bLine = idx < bc ? batchLines[idx] : nil
        if sLine != bLine {
          let sDesc = sLine.map { spansToDebugString($0) } ?? "(missing)"
          let bDesc = bLine.map { spansToDebugString($0) } ?? "(missing)"
          diffs.append("[\(idx)] streaming:'\(sDesc)' batch:'\(bDesc)'")
        }
      }
      if !diffs.isEmpty {
        detail += " diffs={" + diffs.joined(separator: ", ") + "}"
      }
      return detail
    }()

    return ApplyResult(needsRender: true, driftDetail: drift)
  }

  // MARK: - Helpers

  /// Renders a TLine into a compact debug string for log output.
  private func spansToDebugString(_ line: TLine) -> String {
    line.spans.map { $0.text }.joined()
  }
}

// MARK: - ApplyResult

struct ApplyResult: Equatable {
  /// Whether the caller should request a render frame.
  var needsRender: Bool
  /// If non-nil, the streaming render produced a drift from the batch
  /// render (logged as a warning by the host).
  var driftDetail: String? = nil
}
