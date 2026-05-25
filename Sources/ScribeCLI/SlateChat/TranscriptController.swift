import Foundation
import ScribeCore
import ScribeLLM


/// Pure-value container for all transcript state the host manages.
/// Owned by `TranscriptController`; the host holds a copy and passes
/// it to `TranscriptController.apply()` on every event.
struct TranscriptState: Equatable {
  /// Completed transcript lines (user messages, finalized assistant turns, tool output).
  var lines: [TLine] = []
  /// Open line being built during streaming (nil when idle).
  var streamingOpenLine: TLine? = nil
  var streamingOpenLineRaw: String = ""
  var streamingSectionStartLineIndex: Int? = nil
  var currentStreamingSection: AssistantStreamSection = .answer
  /// Bumped when transcript structure changes (for FlattenCache invalidation).
  var generation: Int = 0

  // Usage tracking
  var usageTurnPrompt: Int = 0
  var usageTurnCompletion: Int = 0
  var usageTurnTotal: Int = 0
  var usageSessionPrompt: Int = 0
  var usageSessionCompletion: Int = 0
  var usageSessionTotal: Int = 0
  var usageHUD: UsageHUDSnapshot? = nil
}


/// Pure state machine for transcript events.
///
/// All state mutations happen here. Side effects (render requests) are
/// returned as `Effects` for the host to execute. The controller holds
/// no references to `SlateCore`, `@MainActor`, or any async machinery —
/// it is unit-testable with no TUI infrastructure.
struct TranscriptController {

  /// Side effects the host must perform after applying an event.
  struct Effects: Equatable {
    var needsRender: Bool = false
  }

  /// Apply a transcript event to the given state, returning effects.
  /// - Parameters:
  ///   - state: Mutable transcript state (inout).
  ///   - event: The transcript event to process.
  ///   - theme: CLI color theme for span construction.
  ///   - renderer: Markdown renderer for streaming/batch rendering.
  ///   - followingLive: Whether the viewport is tail-following live output.
  ///   - contextWindow: Optional context window size for usage percentage.
  /// - Returns: Side effects the host must execute.
  static func apply(
    _ event: AgentEvent,
    to state: inout TranscriptState,
    theme: CLITheme,
    renderer: MarkdownRenderer,
    followingLive: Bool,
    contextWindow: Int?
  ) -> Effects {
    switch event {
    case .output(.sectionStarted(let section, let previous)):
      return applyEnterAssistantSection(section, previous: previous, state: &state, theme: theme)

    case .output(.text(let section, let text)):
      return applyAppendAssistantText(
        section, text: text, state: &state, theme: theme, renderer: renderer, followingLive: followingLive)

    case .output(.finalized):
      return applyFinalizeAssistantStream(state: &state, theme: theme, renderer: renderer)

    case .output(.empty):
      return applyEmptyAssistantTurn(state: &state, theme: theme)

    case .tool(.invocation(let name, let arguments, let output)):
      return applyToolInvocation(name: name, arguments: arguments, output: output, state: &state, theme: theme)

    case .tool(.warning(let message)):
      state.lines.append(
        TLine(spans: [
          StyledSpan(fg: theme.warningFG, bg: theme.background, bold: false, text: "warning: \(message)")
        ]))
      return Effects(needsRender: true)

    case .lifecycle(.usage(let usage, let tps)):
      return applyUsage(usage, tokensPerSecond: tps, state: &state, contextWindow: contextWindow)

    case .lifecycle(.error(let error)):
      state.lines.append(
        TLine(spans: [
          StyledSpan(
            fg: theme.errorFG, bg: theme.background, bold: false,
            text: "error: \(error.errorDescription ?? String(describing: error))")
        ]))
      return Effects(needsRender: true)

    case .lifecycle(.interrupted):
      state.lines.append(
        TLine(spans: [
          StyledSpan(fg: theme.interruptedFG, bg: theme.background, bold: false, text: "(interrupted)")
        ]))
      state.streamingOpenLine = nil
      state.streamingOpenLineRaw = ""
      state.streamingSectionStartLineIndex = nil
      return Effects(needsRender: true)

    case .lifecycle(.recovered(let reason)):
      state.lines.append(
        TLine(spans: [
          StyledSpan(fg: theme.warningFG, bg: theme.background, bold: false, text: "(recovered: \(reason))")
        ]))
      return Effects(needsRender: true)
    }
  }


  private static func applyEnterAssistantSection(
    _ section: AssistantStreamSection,
    previous: AssistantStreamSection?,
    state: inout TranscriptState,
    theme: CLITheme
  ) -> Effects {
    // Finalize previous open line if any.
    if let open = state.streamingOpenLine {
      state.lines.append(open)
      state.streamingOpenLine = nil
    }
    if previous != nil {
      if previous == .reasoning && section == .answer {
        state.lines.append(TLine(spans: []))
      }
    } else {
      if let last = state.lines.last, isUserSubmissionLine(last, theme: theme) {
        state.lines.append(TLine(spans: []))
      }
    }
    let header = TLine(spans: [
      StyledSpan(fg: theme.scribePrefix, bg: theme.background, bold: false, text: "scribe:")
    ])
    state.lines.append(header)
    switch section {
    case .reasoning:
      state.lines.append(
        TLine(spans: [
          StyledSpan(fg: theme.sectionLabel, bg: theme.background, bold: false, text: "  · reasoning")
        ]))
    case .answer:
      state.lines.append(
        TLine(spans: [
          StyledSpan(fg: theme.sectionLabel, bg: theme.background, bold: false, text: "  · answer")
        ]))
    }
    state.streamingOpenLine = TLine(spans: [])
    state.streamingOpenLineRaw = ""
    state.streamingSectionStartLineIndex = state.lines.count
    state.currentStreamingSection = section
    return Effects(needsRender: true)
  }

  private static func applyAppendAssistantText(
    _ section: AssistantStreamSection,
    text: String,
    state: inout TranscriptState,
    theme: CLITheme,
    renderer: MarkdownRenderer,
    followingLive: Bool
  ) -> Effects {
    if state.streamingOpenLine == nil {
      state.streamingOpenLine = TLine(spans: [])
      state.streamingOpenLineRaw = ""
    }
    state.streamingOpenLineRaw += text
    state.currentStreamingSection = section

    // When the user has scrolled up, skip per-chunk rendering.
    guard followingLive else { return Effects(needsRender: false) }

    let st = theme.style(for: section)

    // Only render the visible tail during streaming.
    let maxVisibleLogicalLines = 200
    let tailText: String = {
      let allLines = state.streamingOpenLineRaw.split(separator: "\n", omittingEmptySubsequences: false)
      guard allLines.count > maxVisibleLogicalLines else {
        return state.streamingOpenLineRaw
      }
      return allLines.suffix(maxVisibleLogicalLines).joined(separator: "\n")
    }()

    let rendered = renderer.renderStreaming(
      text: tailText,
      baseFG: st.fg,
      baseBold: st.bold,
      theme: section == .reasoning ? .grayscale : theme.markdown
    )
    if let startIdx = state.streamingSectionStartLineIndex {
      let removeCount = max(0, state.lines.count - startIdx)
      if removeCount > 0 {
        state.lines.removeLast(removeCount)
        state.generation &+= 1
      }
    }
    if rendered.isEmpty {
      state.streamingOpenLine = TLine(spans: [])
    } else {
      state.lines.append(contentsOf: rendered.dropLast())
      state.streamingOpenLine = rendered.last!
    }
    return Effects(needsRender: true)
  }

  private static func applyFinalizeAssistantStream(
    state: inout TranscriptState,
    theme: CLITheme,
    renderer: MarkdownRenderer
  ) -> Effects {
    // Re-render accumulated text with full block-level markdown.
    if state.streamingSectionStartLineIndex != nil {
      let section = state.currentStreamingSection
      let st = theme.style(for: section)
      let mdTheme = section == .reasoning ? MarkdownTheme.grayscale : theme.markdown
      let fullRender = renderer.render(
        text: state.streamingOpenLineRaw,
        baseFG: st.fg,
        baseBold: st.bold,
        theme: mdTheme
      )
      if let startIdx = state.streamingSectionStartLineIndex {
        let removeCount = max(0, state.lines.count - startIdx)
        if removeCount > 0 {
          state.lines.removeLast(removeCount)
          state.generation &+= 1
        }
        if fullRender.isEmpty {
          state.streamingOpenLine = TLine(spans: [])
        } else {
          state.lines.append(contentsOf: fullRender.dropLast())
          state.streamingOpenLine = fullRender.last!
        }
      }
    }
    if let open = state.streamingOpenLine {
      state.lines.append(open)
      state.streamingOpenLine = nil
    }
    state.streamingOpenLineRaw = ""
    state.streamingSectionStartLineIndex = nil
    state.lines.append(TLine(spans: []))
    return Effects(needsRender: true)
  }

  private static func applyEmptyAssistantTurn(
    state: inout TranscriptState,
    theme: CLITheme
  ) -> Effects {
    let lineA = TLine(spans: [
      StyledSpan(fg: theme.scribePrefix, bg: theme.background, bold: false, text: "scribe:")
    ])
    let lineB = TLine(spans: [
      StyledSpan(fg: theme.emptyTurn, bg: theme.background, bold: false, text: "(empty turn)")
    ])
    state.lines.append(lineA)
    state.lines.append(lineB)
    return Effects(needsRender: true)
  }

  private static func applyUsage(
    _ usage: ScribeUsage,
    tokensPerSecond tps: Double?,
    state: inout TranscriptState,
    contextWindow: Int?
  ) -> Effects {
    guard let triple = usage.scribeReportedPromptCompletionTotal else { return Effects(needsRender: false) }
    state.usageTurnPrompt += triple.prompt
    state.usageTurnCompletion += triple.completion
    state.usageTurnTotal += triple.total
    state.usageSessionPrompt += triple.prompt
    state.usageSessionCompletion += triple.completion
    state.usageSessionTotal += triple.total
    let pct: Int? = {
      guard let cw = contextWindow, cw > 0, triple.prompt > 0 else { return nil }
      return min(100, Int(Double(triple.prompt) / Double(cw) * 100))
    }()
    state.usageHUD = UsageHUDSnapshot(
      roundPrompt: triple.prompt,
      roundCompletion: triple.completion,
      roundTotal: triple.total,
      turnPrompt: state.usageTurnPrompt,
      turnCompletion: state.usageTurnCompletion,
      turnTotal: state.usageTurnTotal,
      sessionPrompt: state.usageSessionPrompt,
      sessionCompletion: state.usageSessionCompletion,
      sessionTotal: state.usageSessionTotal,
      reasoningTokens: usage.reasoningTokens,
      cachedPromptTokens: usage.cachedPromptTokens,
      outputTokensPerSecond: tps,
      contextWindow: contextWindow,
      contextWindowUsedPercent: pct
    )
    return Effects(needsRender: true)
  }

  private static func applyToolInvocation(
    name: String,
    arguments: String,
    output: String,
    state: inout TranscriptState,
    theme: CLITheme
  ) -> Effects {
    let argSummary = ToolInvocationFormatting.argumentSummary(name: name, argumentsJSON: arguments)
    let outputLines = ToolInvocationFormatting.outputLines(name: name, jsonOutput: output)
    var spans: [StyledSpan] = [
      StyledSpan(fg: theme.toolInvocation, bg: theme.background, bold: false, text: "▶ \(name)")
    ]
    if let argSummary {
      spans.append(StyledSpan(fg: theme.toolArgSummary, bg: theme.background, bold: false, text: " \(argSummary)"))
    }
    state.lines.append(TLine(spans: spans))
    for ol in outputLines {
      state.lines.append(
        TLine(spans: [
          StyledSpan(fg: theme.toolOutput, bg: theme.background, bold: false, text: "  \(ol)")
        ]))
    }
    state.lines.append(TLine(spans: []))
    return Effects(needsRender: true)
  }

  static func applyUserSubmitted(
    _ text: String,
    state: inout TranscriptState,
    theme: CLITheme
  ) -> Effects {
    guard !text.isEmpty else { return Effects(needsRender: false) }
    let logicalLines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    state.lines.append(
      TLine(spans: [
        StyledSpan(fg: theme.userPrefix, bg: theme.background, bold: false, text: "you:")
      ]))
    for row in logicalLines {
      if row.isEmpty {
        state.lines.append(TLine(spans: []))
        continue
      }
      state.lines.append(
        TLine(spans: [
          StyledSpan(fg: theme.userBody, bg: theme.background, bold: false, text: "  \(row)")
        ]))
    }
    return Effects(needsRender: true)
  }


  private static func isUserSubmissionLine(_ line: TLine, theme: CLITheme) -> Bool {
    guard !line.spans.isEmpty else { return false }
    let s = line.spans[0]
    // Match "you:" prefix OR user body text (for blank-line insertion)
    if !s.bold && s.bg == theme.background {
      if s.fg == theme.userPrefix && s.text == "you:" { return true }
      if s.fg == theme.userBody { return true }
    }
    return false
  }
}
