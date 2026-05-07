import Foundation
import ScribeLLM

/// Accumulates one assistant step from streamed chunks (content + parallel tool calls).
public struct StreamedAssistantTurn {
  public var text = ""
  /// Accumulated thinking/reasoning stream; must be sent back as `reasoning_content` on the next API call for providers such as DeepSeek.
  public var reasoningText = ""
  public var toolCalls: [Int: PartialToolCall] = [:]
  public var finishReason: String?

  public struct PartialToolCall {
    public var id: String?
    public var name: String?
    public var arguments: String

    public init(id: String? = nil, name: String? = nil, arguments: String = "") {
      self.id = id
      self.name = name
      self.arguments = arguments
    }
  }

  public init() {}

  public mutating func apply(chunk: Components.Schemas.ChatCompletionChunk) {
    guard let choices = chunk.choices else { return }
    for choice in choices {
      if let fr = choice.finishReason {
        finishReason = fr
      }
      guard let delta = choice.delta else { continue }
      for piece in [delta.reasoningContent, delta.reasoning].compactMap({ $0 }).filter({ !$0.isEmpty }) {
        reasoningText += piece
      }
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

  public func resolvedToolCalls() -> [(id: String, name: String, arguments: String)] {
    toolCalls.keys.sorted().compactMap { key in
      guard let t = toolCalls[key], let id = t.id, let name = t.name else { return nil }
      return (id, name, t.arguments)
    }
  }
}
