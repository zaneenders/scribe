import Foundation
import ScribeLLM

/// Replays a persisted conversation (e.g. from `ChatSessionArchive`) by emitting
/// `TranscriptEvent` values and recording user submissions, so CLI rendering code
/// never needs to import ScribeLLM directly.
public enum TranscriptReplay {

  /// Walk `messages` (skipping the leading system message) and call `onEvent` /
  /// `recordUserSubmission` for each turn so the host can rebuild its scrollback.
  public static func replay(
    messages: [Components.Schemas.ChatMessage],
    onEvent: @escaping @Sendable (TranscriptEvent) -> Void,
    recordUserSubmission: @escaping @Sendable (String) -> Void
  ) {
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
          recordUserSubmission(t)
        }
        i += 1
      case .assistant:
        let text = msg.content ?? ""
        let calls = msg.toolCalls ?? []
        let reasoning = msg.reasoningContent ?? ""

        var section: AssistantStreamSection? = nil
        if !reasoning.isEmpty {
          onEvent(.enterAssistantSection(.reasoning, previous: nil))
          onEvent(.appendAssistantText(.reasoning, text: reasoning))
          section = .reasoning
        }

        if !text.isEmpty || section == nil {
          onEvent(.enterAssistantSection(.answer, previous: section))
          if !text.isEmpty {
            onEvent(.appendAssistantText(.answer, text: text))
          }
        }
        onEvent(.finalizeAssistantStream)

        if !calls.isEmpty {
          toolRoundCounter += 1
          let names = calls.map { $0.function?.name ?? "(tool)" }
          onEvent(.toolRoundHeader(round: toolRoundCounter, toolNames: names))

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
            onEvent(.toolInvocation(name: name, argumentSummary: argSummary, outputLines: lines))
            onEvent(.blankLine)
          }
          i = k
        } else {
          i += 1
        }
        onEvent(.blankLine)
      case .tool:
        i += 1
      }
    }
  }
}
