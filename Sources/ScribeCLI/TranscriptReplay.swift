import Foundation
import ScribeCore
import ScribeLLM
import SlateCore

// MARK: - Rendering messages to transcript lines

/// Render a list of `ChatMessage`s into styled transcript lines.
/// Pure function — no side effects, no state.
public func renderMessagesToTranscript(
  _ messages: [Components.Schemas.ChatMessage],
  theme: CLITheme,
  renderer: MarkdownRenderer
) -> [TLine] {
  var lines: [TLine] = []
  var i = 0
  // Skip leading system message(s).
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
      let text = msg.content ?? ""
      let calls = msg.toolCalls ?? []
      let reasoning = msg.reasoningContent ?? ""

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
        let adapter = MarkdownToSlateAdapter(
          theme: .grayscale, bodyFG: st.fg, bodyBold: st.bold)
        let rendered = renderer.render(text: reasoning)
        lines.append(contentsOf: adapter.convert(rendered))
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
          let adapter = MarkdownToSlateAdapter(
            theme: theme.markdown, bodyFG: st.fg, bodyBold: st.bold)
          let rendered = renderer.render(text: text)
          lines.append(contentsOf: adapter.convert(rendered))
        }
      }

      if !calls.isEmpty {
        toolRoundCounter += 1
        let names = calls.map { $0.function?.name ?? "(tool)" }
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
            toolBodies[tid] = messages[k].content ?? ""
          }
          k += 1
        }

        for tc in calls {
          let id = tc.id ?? ""
          let name = tc.function?.name ?? "tool"
          let args = tc.function?.arguments ?? "{}"
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
  return lines
}
