import Foundation
import ScribeLLM
import ScribeLLMResponses
import SystemPackage
import Testing

@testable import ScribeCore

@Test
func responsesUserMessageWithTextOnly() {
  let text = "Hello, how are you?"
  let msg = ScribeLLM.Components.Schemas.ChatMessage(
    role: .user,
    content: .case1(text)
  )

  let result = convertChatMessagesToResponsesInput([msg])

  #expect(result?.count == 1)
  guard let items = result, let first = items.first else {
    Issue.record("Expected one item")
    return
  }
  guard case .user(let userMsg) = first else {
    Issue.record("Expected a .user item")
    return
  }
  guard case .case1(let resultText) = userMsg.content else {
    Issue.record("Expected .case1 content, got .case2")
    return
  }
  #expect(resultText == text)
}

@Test
func responsesUserMessageWithImageAndTextParts() {
  let imageURL =
    "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="
  let textContent = "What do you see in this image?"

  let textPart: ScribeLLM.Components.Schemas.ChatContentPart = .text(
    ScribeLLM.Components.Schemas.ChatTextContentPart(
      _type: .text,
      text: textContent
    )
  )
  let imagePart: ScribeLLM.Components.Schemas.ChatContentPart = .imageUrl(
    ScribeLLM.Components.Schemas.ChatImageContentPart(
      _type: .imageUrl,
      imageUrl: ScribeLLM.Components.Schemas.ChatImageContentPart.ImageUrlPayload(
        url: imageURL,
        detail: .auto
      ),
      additionalProperties: .init()
    )
  )

  let msg = ScribeLLM.Components.Schemas.ChatMessage(
    role: .user,
    content: .case2([textPart, imagePart])
  )

  let result = convertChatMessagesToResponsesInput([msg])

  #expect(result?.count == 1)
  guard let items = result, let first = items.first else {
    Issue.record("Expected one item")
    return
  }
  guard case .user(let userMsg) = first else {
    Issue.record("Expected a .user item")
    return
  }
  guard case .case2(let parts) = userMsg.content else {
    Issue.record("Expected .case2 content, got .case1")
    return
  }
  #expect(parts.count == 2)

  guard case .inputText(let responsesText) = parts[0] else {
    Issue.record("Expected first part to be inputText")
    return
  }
  #expect(responsesText.text == textContent)

  guard case .inputImage(let responsesImage) = parts[1] else {
    Issue.record("Expected second part to be inputImage")
    return
  }
  #expect(responsesImage.imageUrl == imageURL)
  #expect(responsesImage.detail == .auto)
}

@Test
func responsesReadFileAttachmentUsesSixPixelBase64ImageContentArray() async throws {
  let pngBase64 =
    "iVBORw0KGgoAAAANSUhEUgAAAAMAAAACCAYAAACddGYaAAAAFUlEQVR4nGP4z8DwH4QZGBgYGBgAAEKFCf6R29pAAAAAAElFTkSuQmCC"
  let png = try #require(Data(base64Encoded: pngBase64))
  #expect(png.count > 24)
  #expect(png[16..<24].elementsEqual([0, 0, 0, 3, 0, 0, 0, 2]))

  try await withTemporaryDirectory { directory in
    let imageURL = directory.appendingPathComponent("six-pixels.png")
    try png.write(to: imageURL)
    let registry = ToolRegistry(tools: [ReadFileTool()], logger: toolRunnerTestLogger)
    let result = try await registry.run(
      name: "read_file",
      arguments: try jsonArguments(["path": imageURL.path]),
      workingDirectory: FilePath(directory.path),
      logger: toolRunnerTestLogger,
      abortObserver: AbortNotifier()
    )
    let attachment = try #require(result.attachments.first)
    let message = toolAttachmentMessage(attachment)

    guard case .case2(let chatParts) = message.content else {
      Issue.record("Image input must be an array of content objects")
      return
    }
    #expect(chatParts.count == 2)
    guard case .imageUrl(let chatImage) = chatParts[1] else {
      Issue.record("Expected the second content object to be an image")
      return
    }
    #expect(chatImage.imageUrl.url == "data:image/png;base64,\(pngBase64)")

    let items = try #require(convertChatMessagesToResponsesInput([message]))
    guard case .user(let user) = items[0], case .case2(let responsesParts) = user.content else {
      Issue.record("Expected a Responses user message with an input content array")
      return
    }
    #expect(responsesParts.count == 2)
    guard case .inputImage(let image) = responsesParts[1] else {
      Issue.record("Expected Responses input_image content")
      return
    }
    #expect(image.imageUrl == "data:image/png;base64,\(pngBase64)")
  }
}

@Test
func responsesUserMessageWithImageOnly() {
  let imageURL =
    "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="

  let imagePart: ScribeLLM.Components.Schemas.ChatContentPart = .imageUrl(
    ScribeLLM.Components.Schemas.ChatImageContentPart(
      _type: .imageUrl,
      imageUrl: ScribeLLM.Components.Schemas.ChatImageContentPart.ImageUrlPayload(
        url: imageURL,
        detail: .high
      ),
      additionalProperties: .init()
    )
  )

  let msg = ScribeLLM.Components.Schemas.ChatMessage(
    role: .user,
    content: .case2([imagePart])
  )

  let result = convertChatMessagesToResponsesInput([msg])

  #expect(result?.count == 1)
  guard let items = result, let first = items.first else {
    Issue.record("Expected one item")
    return
  }
  guard case .user(let userMsg) = first else {
    Issue.record("Expected a .user item")
    return
  }
  guard case .case2(let parts) = userMsg.content else {
    Issue.record("Expected .case2 content")
    return
  }
  #expect(parts.count == 1)
  guard case .inputImage(let responsesImage) = parts[0] else {
    Issue.record("Expected inputImage")
    return
  }
  #expect(responsesImage.imageUrl == imageURL)
  #expect(responsesImage.detail == .high)
}

@Test
func responsesMessageConversionSanitizesForeignToolCallIDs() {
  let foreignID = "tool_3AXlpi3mBRnQCMzIr7HgDba0"
  let assistantMsg = ScribeLLM.Components.Schemas.ChatMessage(
    role: .assistant,
    content: .case1("Let me check that file."),
    toolCalls: [
      ScribeLLM.Components.Schemas.AssistantToolCall(
        id: foreignID,
        _type: "function",
        function: ScribeLLM.Components.Schemas.AssistantToolCall.FunctionPayload(
          name: "read_file",
          arguments: #"{}"#
        )
      )
    ]
  )
  let toolMsg = ScribeLLM.Components.Schemas.ChatMessage(
    role: .tool,
    content: .case1("file contents"),
    toolCallId: foreignID
  )

  let items = convertChatMessagesToResponsesInput([assistantMsg, toolMsg])

  guard let items, items.count == 3,
    case .functionCall(let call) = items[1],
    case .functionCallOutput(let output) = items[2]
  else {
    Issue.record("Expected assistant + functionCall + functionCallOutput items")
    return
  }
  #expect(call.id?.hasPrefix("fc_") == true)
  #expect(call.callId.hasPrefix("call_"))
  #expect(output.callId == call.callId)
}

@Test
func responsesMessageConversionPreservesSystemAndToolMessages() {
  let systemMsg = ScribeLLM.Components.Schemas.ChatMessage(
    role: .system,
    content: .case1("You are a helpful assistant.")
  )
  let userMsg = ScribeLLM.Components.Schemas.ChatMessage(
    role: .user,
    content: .case1("Run ls")
  )
  let assistantMsg = ScribeLLM.Components.Schemas.ChatMessage(
    role: .assistant,
    content: .case1("Let me run that command."),
    toolCalls: [
      ScribeLLM.Components.Schemas.AssistantToolCall(
        id: "call_abc123",
        _type: "function",
        function: ScribeLLM.Components.Schemas.AssistantToolCall.FunctionPayload(
          name: "shell",
          arguments: #"{"command":"ls"}"#
        )
      )
    ]
  )
  let toolMsg = ScribeLLM.Components.Schemas.ChatMessage(
    role: .tool,
    content: .case1("README.md\nSources\nTests"),
    toolCallId: "call_abc123"
  )

  guard
    let items = convertChatMessagesToResponsesInput(
      [systemMsg, userMsg, assistantMsg, toolMsg]
    )
  else {
    Issue.record("Expected non-nil result")
    return
  }

  #expect(items.count == 5)

  guard case .system(let sys) = items[0] else {
    Issue.record("Expected .system at index 0")
    return
  }
  #expect(sys.content == "You are a helpful assistant.")

  guard case .user(let usr) = items[1] else {
    Issue.record("Expected .user at index 1")
    return
  }
  guard case .case1(let userText) = usr.content else {
    Issue.record("Expected .case1 for user")
    return
  }
  #expect(userText == "Run ls")

  guard case .assistant(let asst) = items[2] else {
    Issue.record("Expected .assistant at index 2")
    return
  }
  guard case .case1(let asstText) = asst.content else {
    Issue.record("Expected .case1 for assistant")
    return
  }
  #expect(asstText == "Let me run that command.")

  guard case .functionCall(let fc) = items[3] else {
    Issue.record("Expected .functionCall at index 3")
    return
  }
  #expect(fc.name == "shell")
  #expect(fc.arguments == #"{"command":"ls"}"#)

  guard case .functionCallOutput(let fco) = items[4] else {
    Issue.record("Expected .functionCallOutput at index 4")
    return
  }
  guard case .case1(let outputText) = fco.output else {
    Issue.record("Expected .case1 for function call output")
    return
  }
  #expect(outputText == "README.md\nSources\nTests")
}
