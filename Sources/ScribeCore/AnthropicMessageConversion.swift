import Foundation
import OpenAPIRuntime
import ScribeLLM
import ScribeLLMAnthropic

// Type alias to resolve ambiguity between ScribeLLM.Components and ScribeLLMAnthropic.Components
typealias AnthropicComponents = ScribeLLMAnthropic.Components

// MARK: - Message Conversion (ScribeMessage ↔ Anthropic wire format)

/// Converts a system prompt string into Anthropic's top-level `system` field format.
func toAnthropicSystem(_ systemPrompt: String?) -> AnthropicComponents.Schemas.CreateMessageRequest.SystemPayload? {
  guard let prompt = systemPrompt, !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
    return nil
  }
  return .case1(prompt)
}

/// Converts a `ScribeMessage` with role `.tool` into an Anthropic `RequestToolResultBlock` content block.
func toAnthropicToolResult(_ message: ScribeMessage) -> AnthropicComponents.Schemas.RequestToolResultBlock {
  AnthropicComponents.Schemas.RequestToolResultBlock(
    _type: .toolResult,
    toolUseId: message.toolCallId ?? "",
    isError: false,
    content: .case1(message.content)
  )
}

/// Converts an array of `ScribeMessage` into Anthropic `InputMessage` array.
func toAnthropicMessages(_ messages: [ScribeMessage]) -> [AnthropicComponents.Schemas.InputMessage] {
  typealias InputMessage = AnthropicComponents.Schemas.InputMessage
  typealias InputContentBlock = AnthropicComponents.Schemas.InputContentBlock
  typealias RequestToolResultBlock = AnthropicComponents.Schemas.RequestToolResultBlock
  typealias RequestToolUseBlock = AnthropicComponents.Schemas.RequestToolUseBlock

  var result: [InputMessage] = []
  var pendingToolResults: [RequestToolResultBlock] = []
  var pendingToolResultIDs: Set<String> = []

  func flushToolResults() {
    guard !pendingToolResults.isEmpty else { return }
    let blocks: [InputContentBlock] = pendingToolResults.map {
      .toolResult($0)
    }
    let content: InputMessage.ContentPayload = .case2(blocks)
    result.append(InputMessage(role: .user, content: content))
    pendingToolResults.removeAll()
    pendingToolResultIDs.removeAll()
  }

  for message in messages {
    switch message.role {
    case .system:
      continue

    case .user:
      flushToolResults()
      let blocks = scribeContentToAnthropicBlocks(message.contentParts)
      let content: InputMessage.ContentPayload
      if blocks.count == 1, case .text(let tb) = blocks[0] {
        content = .case1(tb.text)
      } else {
        content = .case2(blocks)
      }
      result.append(InputMessage(role: .user, content: content))

    case .assistant:
      flushToolResults()
      var blocks: [InputContentBlock] = []

      if let reasoning = message.reasoning, !reasoning.isEmpty {
        blocks.append(.text(.init(_type: .text, text: reasoning)))
      }

      let textContent = message.contentParts.compactMap { part -> String? in
        if case .text(let t) = part { return t }
        return nil
      }.joined()
      if !textContent.isEmpty {
        blocks.append(.text(.init(_type: .text, text: textContent)))
      }

      if let toolCalls = message.toolCalls {
        for tc in toolCalls {
          let inputObj = parseToolArguments(tc.arguments)
          blocks.append(.toolUse(RequestToolUseBlock(
            _type: .toolUse,
            id: tc.id,
            name: tc.name,
            input: inputObj
          )))
        }
      }

      if blocks.isEmpty {
        blocks.append(.text(.init(_type: .text, text: "")))
      }

      result.append(InputMessage(
        role: .assistant,
        content: .case2(blocks)
      ))

    case .tool:
      let tr = toAnthropicToolResult(message)
      let trID = tr.toolUseId
      if !pendingToolResultIDs.contains(trID) {
        pendingToolResults.append(tr)
        pendingToolResultIDs.insert(trID)
      }
    }
  }

  flushToolResults()

  return result
}

// MARK: - Private Helpers

private func scribeContentToAnthropicBlocks(_ parts: [ScribeContentPart]) -> [AnthropicComponents.Schemas.InputContentBlock] {
  typealias SourcePayload = AnthropicComponents.Schemas.RequestImageBlock.SourcePayload
  typealias MediaType = SourcePayload.MediaTypePayload

  return parts.map { part in
    switch part {
    case .text(let text):
      return .text(.init(_type: .text, text: text))
    case .image(let url, _):
      let (mediaType, base64Data) = parseImageURL(url)
      return .image(.init(
        _type: .image,
        source: SourcePayload(
          _type: .base64,
          mediaType: mediaType,
          data: base64Data
        )
      ))
    }
  }
}

private func parseImageURL(_ url: String) -> (AnthropicComponents.Schemas.RequestImageBlock.SourcePayload.MediaTypePayload, String) {
  typealias MediaType = AnthropicComponents.Schemas.RequestImageBlock.SourcePayload.MediaTypePayload
  let defaultMediaType = MediaType.imagePng
  if url.hasPrefix("data:") {
    let parts = url.dropFirst(5).split(separator: ";", maxSplits: 1)
    let mimeType = String(parts[0])
    let dataPart = parts.count > 1 ? String(parts[1]) : ""
    let base64 = dataPart.hasPrefix("base64,") ? String(dataPart.dropFirst(7)) : dataPart

    let mediaType: MediaType = {
      switch mimeType {
      case "image/jpeg": return .imageJpeg
      case "image/gif": return .imageGif
      case "image/webp": return .imageWebp
      default: return .imagePng
      }
    }()
    return (mediaType, base64)
  }
  return (defaultMediaType, url)
}

private func parseToolArguments(_ json: String) -> AnthropicComponents.Schemas.RequestToolUseBlock.InputPayload {
  guard let data = json.data(using: .utf8) else {
    return AnthropicComponents.Schemas.RequestToolUseBlock.InputPayload()
  }
  return (try? JSONDecoder().decode(
    AnthropicComponents.Schemas.RequestToolUseBlock.InputPayload.self,
    from: data
  )) ?? AnthropicComponents.Schemas.RequestToolUseBlock.InputPayload()
}

// MARK: - Reverse conversion (Anthropic response → ScribeMessage)

struct AnthropicResponseContent {
  var text: String = ""
  var reasoning: String = ""
  var toolCalls: [ScribeToolCall] = []
}

func extractAnthropicContent(_ blocks: [AnthropicComponents.Schemas.ContentBlock]) -> AnthropicResponseContent {
  var result = AnthropicResponseContent()

  for block in blocks {
    switch block {
    case .text(let tb):
      result.text += tb.text
    case .toolUse(let tu):
      let argsJSON: String
      if let data = try? JSONSerialization.data(
        withJSONObject: tu.input.additionalProperties.value,
        options: []
      ),
         let json = String(data: data, encoding: .utf8) {
        argsJSON = json
      } else {
        argsJSON = "{}"
      }
      result.toolCalls.append(ScribeToolCall(
        id: tu.id,
        name: tu.name,
        arguments: argsJSON
      ))
    }
  }

  return result
}

fileprivate func toCompletionUsage(_ usage: AnthropicComponents.Schemas.Usage) -> ScribeLLM.Components.Schemas.CompletionUsage {
  ScribeLLM.Components.Schemas.CompletionUsage(
    promptTokens: usage.inputTokens,
    completionTokens: usage.outputTokens,
    totalTokens: usage.inputTokens + usage.outputTokens,
    promptTokensDetails: nil,
    completionTokensDetails: nil
  )
}
