import Foundation
import ScribeLLM

/// Accumulates one assistant step from streamed chunks (content + parallel tool calls).
struct StreamedAssistantTurn {
  var text = ""
  var toolCalls: [Int: PartialToolCall] = [:]
  var finishReason: String?

  struct PartialToolCall {
    var id: String?
    var name: String?
    var arguments: String
  }

  mutating func apply(chunk: Components.Schemas.ChatCompletionChunk) {
    guard let choices = chunk.choices else { return }
    for choice in choices {
      if let fr = choice.finishReason {
        finishReason = fr
      }
      guard let delta = choice.delta else { continue }
      if let c = delta.content, !c.isEmpty {
        text += c
      }
      guard let deltas = delta.toolCalls else { continue }
      for td in deltas {
        let idx = td.index ?? 0
        var acc = toolCalls[idx] ?? PartialToolCall(id: nil, name: nil, arguments: "")
        if let id = td.id { acc.id = id }
        if let fn = td.function {
          if let n = fn.name { acc.name = n }
          if let a = fn.arguments { acc.arguments += a }
        }
        toolCalls[idx] = acc
      }
    }
  }

  func resolvedToolCalls() -> [(id: String, name: String, arguments: String)] {
    toolCalls.keys.sorted().compactMap { key in
      guard let t = toolCalls[key], let id = t.id, let name = t.name else { return nil }
      return (id, name, t.arguments)
    }
  }
}
