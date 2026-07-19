import Foundation
import ScribeLLM
import ScribeLLMAnthropic

/// Accumulates streaming content from the Anthropic Messages API.
/// Tracks content blocks (text, tool_use) as they arrive via SSE events.
struct AnthropicAssistantTurn {
  var text = ""
  var reasoningText = ""
  /// Accumulated content blocks keyed by index.
  private var contentBlocks: [Int: AccumulatedBlock] = [:]

  struct AccumulatedBlock {
    enum BlockType {
      case text
      case toolUse(id: String, name: String)
    }

    var type: BlockType
    var text: String = ""
    var argumentsJSON: String = ""

    init(type: BlockType) {
      self.type = type
    }
  }

  typealias ContentBlock = ScribeLLMAnthropic.Components.Schemas.ContentBlock
  typealias ContentBlockPayload = ScribeLLMAnthropic.Components.Schemas.ContentBlockStartEvent.ContentBlockPayload

  mutating func applyContentBlockStart(index: Int, contentBlock: ContentBlock) {
    switch contentBlock {
    case .text(let tb):
      contentBlocks[index] = AccumulatedBlock(type: .text)
      if !tb.text.isEmpty {
        contentBlocks[index]?.text = tb.text
      }
    case .toolUse(let tu):
      contentBlocks[index] = AccumulatedBlock(type: .toolUse(id: tu.id, name: tu.name))
    }
  }

  mutating func applyContentBlockStartPayload(index: Int, payload: ContentBlockPayload) {
    switch payload {
    case .text(let tb):
      contentBlocks[index] = AccumulatedBlock(type: .text)
      if !tb.text.isEmpty {
        contentBlocks[index]?.text = tb.text
      }
    case .toolUse(let tu):
      contentBlocks[index] = AccumulatedBlock(type: .toolUse(id: tu.id, name: tu.name))
    }
  }

  mutating func applyTextDelta(index: Int, text: String) {
    contentBlocks[index]?.text += text
  }

  mutating func applyInputJsonDelta(index: Int, partialJson: String) {
    contentBlocks[index]?.argumentsJSON += partialJson
  }

  mutating func applyContentBlockStop(index: Int) {
    // Block finalized
  }

  func resolvedText() -> String {
    contentBlocks.values
      .filter { if case .text = $0.type { true } else { false } }
      .map(\.text)
      .joined()
  }

  func resolvedReasoning() -> String {
    reasoningText
  }

  func resolvedToolCalls() -> [ToolInvocation] {
    contentBlocks.keys.sorted().compactMap { index -> ToolInvocation? in
      guard let block = contentBlocks[index],
            case .toolUse(let id, let name) = block.type else { return nil }
      let args = block.argumentsJSON.isEmpty ? "{}" : block.argumentsJSON
      return ToolInvocation(id: id, name: name, arguments: args)
    }
  }
}
