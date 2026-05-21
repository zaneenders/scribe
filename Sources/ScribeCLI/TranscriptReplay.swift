import Foundation
import ScribeCore
import SlateCore

// MARK: - Rendering messages to transcript lines

/// Render a list of `ScribeMessage`s into styled transcript lines.
/// Pure function — no side effects, no state.
public func renderMessagesToTranscript(
  _ messages: [ScribeMessage],
  theme: CLITheme,
  renderer: MarkdownRenderer
) -> [TLine] {
  renderMessagesToTranscriptWithStarts(messages, theme: theme, renderer: renderer).lines
}

/// Like `renderMessagesToTranscript` but also returns `messageStartLines` —
/// a parallel array of length `messages.count + 1` mapping a slice cut
/// index to the resulting line index. `messageStartLines[i]` is the line
/// index at which the rendering of `messages[i..<count]` begins; the
/// trailing entry equals `lines.count`. Indices that don't produce their
/// own output (system, tool absorbed into an assistant round) inherit the
/// next produced line so a "cut here" lookup always lands on a sensible
/// row. Used by the `/fork` and `/summarize` boundary picker to position
/// the viewport and draw a divider at the cut.
public func renderMessagesToTranscriptWithStarts(
  _ messages: [ScribeMessage],
  theme: CLITheme,
  renderer: MarkdownRenderer
) -> (lines: [TLine], messageStartLines: [Int]) {
  var lines: [TLine] = []
  // -1 = unset; filled in a backward pass after the main loop.
  var starts: [Int] = Array(repeating: -1, count: messages.count + 1)
  var i = 0
  // Skip leading system message(s).
  while i < messages.count, messages[i].role == .system {
    i += 1
  }
  var toolRoundCounter = 0
  while i < messages.count {
    starts[i] = lines.count
    let msg = messages[i]
    switch msg.role {
    case .system:
      i += 1
    case .user:
      let t = msg.content.trimmingCharacters(in: .whitespacesAndNewlines)
      if !t.isEmpty {
        let logicalLines =
          t.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        lines.append(
          TLine(
            spans: [
              StyledSpan(fg: theme.userPrefix, bg: theme.background, bold: false, text: "you:")
            ]))
        for row in logicalLines {
          if row.isEmpty {
            lines.append(TLine(spans: []))
          } else {
            lines.append(
              TLine(
                spans: [
                  StyledSpan(
                    fg: theme.userBody, bg: theme.background, bold: false, text: "  \(row)")
                ]))
          }
        }
      }
      i += 1
    case .assistant:
      let text = msg.content
      let calls = msg.toolCalls ?? []
      let reasoning = msg.reasoning ?? ""

      // Add blank line separator between user and assistant sections.
      if let last = lines.last, !last.spans.isEmpty {
        let fg = last.spans.first?.fg
        let text = last.spans.first?.text
        if fg == theme.userPrefix && text == "you:" || fg == theme.userBody {
          lines.append(TLine(spans: []))
        }
      }

      var section: AssistantStreamSection? = nil
      if !reasoning.isEmpty {
        lines.append(
          TLine(
            spans: [
              StyledSpan(
                fg: theme.scribePrefix, bg: theme.background, bold: false, text: "scribe:")
            ]))
        lines.append(
          TLine(
            spans: [
              StyledSpan(
                fg: theme.sectionLabel, bg: theme.background, bold: false,
                text: "  · reasoning")
            ]))
        let st = theme.style(for: .reasoning)
        let rendered = renderer.render(
          text: reasoning, baseFG: st.fg, baseBold: st.bold, theme: .grayscale)
        lines.append(contentsOf: rendered)
        section = .reasoning
      }

      if !text.isEmpty || section == nil {
        if section != nil {
          lines.append(TLine(spans: []))
        }
        lines.append(
          TLine(
            spans: [
              StyledSpan(
                fg: theme.scribePrefix, bg: theme.background, bold: false, text: "scribe:")
            ]))
        lines.append(
          TLine(
            spans: [
              StyledSpan(
                fg: theme.sectionLabel, bg: theme.background, bold: false,
                text: "  · answer")
            ]))
        if !text.isEmpty {
          let st = theme.style(for: .answer)
          let rendered = renderer.render(
            text: text, baseFG: st.fg, baseBold: st.bold, theme: theme.markdown)
          lines.append(contentsOf: rendered)
        }
      }

      if !calls.isEmpty {
        toolRoundCounter += 1
        let names = calls.map { $0.name }
        lines.append(
          TLine(spans: [
            StyledSpan(
              fg: theme.toolRoundHeader, bg: theme.background, bold: true,
              text: "tool round \(toolRoundCounter) "),
            StyledSpan(
              fg: theme.toolNames, bg: theme.background, bold: false,
              text: names.joined(separator: ", ")),
          ]))

        var k = i + 1
        var toolBodies: [String: String] = [:]
        while k < messages.count, messages[k].role == .tool {
          if let tid = messages[k].toolCallId {
            toolBodies[tid] = messages[k].content
          }
          k += 1
        }

        for tc in calls {
          let id = tc.id
          let name = tc.name
          let args = tc.arguments
          let jsonOut = toolBodies[id] ?? ""
          let argSummary = ToolInvocationFormatting.argumentSummary(
            name: name, argumentsJSON: args)
          let outputLines = ToolInvocationFormatting.outputLines(
            name: name, jsonOutput: jsonOut)
          var spans: [StyledSpan] = [
            StyledSpan(
              fg: theme.toolInvocation, bg: theme.background, bold: false,
              text: "▶ \(name)")
          ]
          if let argSummary {
            spans.append(
              StyledSpan(
                fg: theme.toolArgSummary, bg: theme.background, bold: false,
                text: " \(argSummary)"))
          }
          lines.append(TLine(spans: spans))
          for ol in outputLines {
            lines.append(
              TLine(
                spans: [
                  StyledSpan(
                    fg: theme.toolOutput, bg: theme.background, bold: false,
                    text: "  \(ol)")
                ]))
          }
          lines.append(TLine(spans: []))
        }
        i = k
      } else {
        i += 1
      }
      lines.append(TLine(spans: []))
    case .tool:
      i += 1
    }
  }
  // Trailing sentinel + backward fill: any message that produced no output
  // of its own inherits the line index of whatever comes after it. This way
  // a cut at an unsafe index still maps somewhere sensible.
  starts[messages.count] = lines.count
  var next = lines.count
  for j in stride(from: messages.count - 1, through: 0, by: -1) {
    if starts[j] == -1 { starts[j] = next } else { next = starts[j] }
  }
  return (lines, starts)
}
