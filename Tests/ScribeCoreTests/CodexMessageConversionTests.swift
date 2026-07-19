import Foundation
import SystemPackage
import Testing

@testable import ScribeCore
import ScribeLLM
import ScribeLLMCodex

@Test
func codexUserMessageWithTextOnly() {
  let text = "Hello, how are you?"
  let msg = ScribeLLM.Components.Schemas.ChatMessage(
    role: .user,
    content: .case1(text)
  )

  let result = convertChatMessagesToCodexInput([msg])

  #expect(result?.count == 1)
  guard let items = result, let first = items.first else {
    Issue.record("Expected one item")
    return
  }
  guard case let .user(userMsg) = first else {
    Issue.record("Expected a .user item")
    return
  }
  guard case let .case1(resultText) = userMsg.content else {
    Issue.record("Expected .case1 content, got .case2")
    return
  }
  #expect(resultText == text)
}

@Test
func codexUserMessageWithImageAndTextParts() {
  let imageURL = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="
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

  let result = convertChatMessagesToCodexInput([msg])

  #expect(result?.count == 1)
  guard let items = result, let first = items.first else {
    Issue.record("Expected one item")
    return
  }
  guard case let .user(userMsg) = first else {
    Issue.record("Expected a .user item")
    return
  }
  guard case let .case2(parts) = userMsg.content else {
    Issue.record("Expected .case2 content, got .case1")
    return
  }
  #expect(parts.count == 2)

  // First part should be text
  guard case let .inputText(codexText) = parts[0] else {
    Issue.record("Expected first part to be inputText")
    return
  }
  #expect(codexText.text == textContent)

  // Second part should be image
  guard case let .inputImage(codexImage) = parts[1] else {
    Issue.record("Expected second part to be inputImage")
    return
  }
  #expect(codexImage.imageUrl == imageURL)
  #expect(codexImage.detail == .auto)
}

@Test
func codexReadFileAttachmentUsesSixPixelBase64ImageContentArray() async throws {
  // A valid 3x2 RGBA PNG: six pixels total.
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
    let message = codexAttachmentMessage(attachment)

    guard case let .case2(chatParts) = message.content else {
      Issue.record("Image input must be an array of content objects")
      return
    }
    #expect(chatParts.count == 2)
    guard case let .imageUrl(chatImage) = chatParts[1] else {
      Issue.record("Expected the second content object to be an image")
      return
    }
    #expect(chatImage.imageUrl.url == "data:image/png;base64,\(pngBase64)")
    try KimiK3Support.validateMessages([message])

    let items = try #require(convertChatMessagesToCodexInput([message]))
    guard case let .user(user) = items[0], case let .case2(codexParts) = user.content else {
      Issue.record("Expected a Codex user message with an input content array")
      return
    }
    #expect(codexParts.count == 2)
    guard case let .inputImage(image) = codexParts[1] else {
      Issue.record("Expected Codex input_image content")
      return
    }
    #expect(image.imageUrl == "data:image/png;base64,\(pngBase64)")
  }
}

@Test
func codexUserMessageWithImageOnly() {
  let imageURL = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="

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

  let result = convertChatMessagesToCodexInput([msg])

  #expect(result?.count == 1)
  guard let items = result, let first = items.first else {
    Issue.record("Expected one item")
    return
  }
  guard case let .user(userMsg) = first else {
    Issue.record("Expected a .user item")
    return
  }
  guard case let .case2(parts) = userMsg.content else {
    Issue.record("Expected .case2 content")
    return
  }
  #expect(parts.count == 1)
  guard case let .inputImage(codexImage) = parts[0] else {
    Issue.record("Expected inputImage")
    return
  }
  #expect(codexImage.imageUrl == imageURL)
  #expect(codexImage.detail == .high)
}

@Test
func codexMessageConversionPreservesSystemAndToolMessages() {
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

  guard let items = convertChatMessagesToCodexInput(
    [systemMsg, userMsg, assistantMsg, toolMsg]
  ) else {
    Issue.record("Expected non-nil result")
    return
  }

  #expect(items.count == 5) // system + user + assistant + functionCall + functionCallOutput

  // 0: System
  guard case let .system(sys) = items[0] else {
    Issue.record("Expected .system at index 0")
    return
  }
  #expect(sys.content == "You are a helpful assistant.")

  // 1: User
  guard case let .user(usr) = items[1] else {
    Issue.record("Expected .user at index 1")
    return
  }
  guard case let .case1(userText) = usr.content else {
    Issue.record("Expected .case1 for user")
    return
  }
  #expect(userText == "Run ls")

  // 2: Assistant
  guard case let .assistant(asst) = items[2] else {
    Issue.record("Expected .assistant at index 2")
    return
  }
  guard case let .case1(asstText) = asst.content else {
    Issue.record("Expected .case1 for assistant")
    return
  }
  #expect(asstText == "Let me run that command.")

  // 3: Function call
  guard case let .functionCall(fc) = items[3] else {
    Issue.record("Expected .functionCall at index 3")
    return
  }
  #expect(fc.name == "shell")
  #expect(fc.arguments == #"{"command":"ls"}"#)

  // 4: Function call output
  guard case let .functionCallOutput(fco) = items[4] else {
    Issue.record("Expected .functionCallOutput at index 4")
    return
  }
  guard case let .case1(outputText) = fco.output else {
    Issue.record("Expected .case1 for function call output")
    return
  }
  #expect(outputText == "README.md\nSources\nTests")
}
