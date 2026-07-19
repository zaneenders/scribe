import Logging
import ScribeLLM
import Testing

@testable import ScribeCore

private func budgetMessage(
  role: ScribeLLM.Components.Schemas.ChatMessage.RolePayload,
  text: String
) -> ScribeLLM.Components.Schemas.ChatMessage {
  .init(role: role, content: .case1(text))
}

@Test
func requestBudgetAllowsSmallRequests() throws {
  var messages = [budgetMessage(role: .user, text: "hello")]
  var newMessages = messages

  let reason = try enforceRequestBudget(
    messages: &messages,
    newMessages: &newMessages,
    tools: [],
    contextWindow: 4_000)

  #expect(reason == nil)
  #expect(messages.count == 1)
}

@Test
func requestBudgetSerializesOpenAPIToolParameters() throws {
  let tool = ShellTool.toChatTool(logger: Logger(label: "test.request-budget"))

  let estimate = try #require(estimateRequestBudget(
    messages: [], tools: [tool], contextWindow: 4_000))

  let metadataBytes =
    tool.function.name.utf8.count + (tool.function.description ?? "").utf8.count
  #expect(estimate.toolDefinitionBytes > metadataBytes)
}

@Test
func requestBudgetRejectsOversizedUserContentBeforeHTTP() throws {
  var messages = [budgetMessage(role: .user, text: String(repeating: "x", count: 20_000))]
  var newMessages = messages

  #expect(throws: ScribeError.self) {
    _ = try enforceRequestBudget(
      messages: &messages,
      newMessages: &newMessages,
      tools: [],
      contextWindow: 4_000)
  }
}

@Test
func requestBudgetCompactsLargeToolResults() throws {
  let user = budgetMessage(role: .user, text: "continue")
  let tool = ScribeLLM.Components.Schemas.ChatMessage(
    role: .tool,
    content: .case1(String(repeating: "x", count: 20_000)),
    name: nil,
    toolCalls: nil,
    toolCallId: "call_1")
  var messages = [user, tool]
  var newMessages = [tool]

  let reason = try enforceRequestBudget(
    messages: &messages,
    newMessages: &newMessages,
    tools: [],
    contextWindow: 4_000)

  #expect(reason?.contains("preflight reduced") == true)
  guard case .case1(let compacted) = messages[1].content else {
    Issue.record("Expected compact tool text")
    return
  }
  #expect(compacted.contains("local preflight estimate"))
  #expect(newMessages.count == 1)
  guard case .case1(let persistedCompaction) = newMessages[0].content else {
    Issue.record("Expected compact persisted tool text")
    return
  }
  #expect(persistedCompaction.contains("local preflight estimate"))
}

@Test
func requestBudgetDoesNotChargeBase64AsText() throws {
  let image = ScribeMessage(
    role: .user,
    contentParts: [
      .text("image"),
      .image(url: "data:image/png;base64," + String(repeating: "A", count: 1_000_000), detail: nil),
    ]
  ).toChatMessage()

  let estimate = try #require(estimateRequestBudget(
    messages: [image], tools: [], contextWindow: 8_000))

  #expect(estimate.textBytes == 5)
  #expect(estimate.imageCount == 1)
  #expect(!estimate.exceedsLimit)
}

@Test
func requestBudgetDisabledWithoutKnownContextWindow() throws {
  var messages = [budgetMessage(role: .user, text: String(repeating: "x", count: 50_000))]
  var newMessages = messages

  #expect(try enforceRequestBudget(
    messages: &messages,
    newMessages: &newMessages,
    tools: [],
    contextWindow: 0) == nil)
}
