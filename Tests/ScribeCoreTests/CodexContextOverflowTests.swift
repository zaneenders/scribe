import Foundation
import HTTPTypes
import Logging
import OpenAPIRuntime
import ScribeLLM
import ScribeLLMCodex
import Synchronization
import SystemPackage
import Testing

@testable import ScribeCore

private final class CodexOverflowTransport: ClientTransport, Sendable {
  private let responseBodies: [String]
  private let state = Mutex(State())

  private struct State {
    var callIndex = 0
    var requestBodies: [Data] = []
  }

  init(responseBodies: [String]) {
    self.responseBodies = responseBodies
  }

  func requests() -> [Data] {
    state.withLock { $0.requestBodies }
  }

  func send(
    _ request: HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String
  ) async throws -> (HTTPResponse, HTTPBody?) {
    var requestData = Data()
    if let body {
      for try await chunk in body { requestData.append(contentsOf: chunk) }
    }
    let responseText = state.withLock { state -> String in
      state.requestBodies.append(requestData)
      let index = min(state.callIndex, responseBodies.count - 1)
      state.callIndex += 1
      return responseBodies[index]
    }
    return (HTTPResponse(status: .ok), HTTPBody(responseText))
  }
}

private struct CodexAttachingExecutor: ToolExecutor {
  func execute(
    _ invocation: ToolInvocation,
    workingDirectory: FilePath,
    logger: Logger,
    abort: any AbortObserver
  ) async throws -> ToolResult {
    ToolResult(
      text: #"{"ok":true,"attached":true}"#,
      attachments: [
        ToolAttachment(
          mimeType: "image/png", base64: "AAAA", filename: "tiny.png", sourcePath: nil)
      ])
  }
}

private let codexOverflowLogger = Logger(label: "test.codex-context-overflow")

private func codexSSE(_ events: String...) -> String {
  events.map { "data: \($0)\n\n" }.joined()
}

private var codexToolCallResponse: String {
  codexSSE(
    #"{"type":"response.output_item.done","item":{"type":"function_call","id":"fc_1","call_id":"call_1","name":"attaching_tool","arguments":"{}"},"output_index":0}"#,
    #"{"type":"response.completed","response":{"id":"resp_tools"}}"#)
}

private var codexContextErrorResponse: String {
  codexSSE(
    #"{"type":"error","error":{"code":"context_length_exceeded","message":"Your input exceeds the context window of this model.","type":"invalid_request_error"}}"#)
}

private var codexCompletedResponse: String {
  codexSSE(
    #"{"type":"response.output_text.delta","delta":"done"}"#,
    #"{"type":"response.completed","response":{"id":"resp_done"}}"#)
}

private func codexOverflowConfig(transport: CodexOverflowTransport) -> CodexAgentLoopConfig {
  CodexAgentLoopConfig(
    model: "test-codex",
    client: ScribeLLMCodex.Client(serverURL: URL(string: "http://test")!, transport: transport),
    accessToken: "",
    accountID: "",
    toolExecutor: CodexAttachingExecutor(),
    chatTools: [],
    maxToolRounds: .max,
    workingDirectory: FilePath("/tmp"),
    reasoningEnabled: nil,
    hooks: .default)
}

@Test
func codexContextOverflowDropsToolAttachmentAndRetries() async throws {
  let transport = CodexOverflowTransport(responseBodies: [
    codexToolCallResponse,
    codexContextErrorResponse,
    codexCompletedResponse,
  ])
  let events = Mutex<[AgentEvent]>([])
  let user = ScribeLLM.Components.Schemas.ChatMessage(role: .user, content: .case1("read image"))

  let (messages, termination) = try await runCodexAgentLoop(
    promptMessages: [user],
    context: AgentContext(messages: []),
    config: codexOverflowConfig(transport: transport),
    emit: { event in events.withLock { $0.append(event) } },
    logger: codexOverflowLogger,
    abortObserver: AbortNotifier())

  #expect(termination == .completed)
  #expect(transport.requests().count == 3)
  #expect(messages.filter { message in
    guard case .case2 = message.content else { return false }
    return true
  }.isEmpty)
  let toolMessage = try #require(messages.first { $0.role == .tool })
  guard case .case1(let toolText) = toolMessage.content else {
    Issue.record("Expected compacted text tool result")
    return
  }
  #expect(toolText.contains("exceeded model context window"))
  #expect(messages.last?.role == .assistant)
  if case .case1(let answer) = messages.last?.content {
    #expect(answer == "done")
  } else {
    Issue.record("Expected final answer")
  }
  let recoveries = events.withLock { events in
    events.compactMap { event -> String? in
      if case .lifecycle(.recovered(let reason)) = event { return reason }
      return nil
    }
  }
  #expect(recoveries.count == 1)
  #expect(recoveries[0].contains("dropped 1 attachment"))

  let retryBody = String(decoding: transport.requests()[2], as: UTF8.self)
  #expect(!retryBody.contains("data:image/png;base64,AAAA"))
  #expect(retryBody.contains("exceeded model context window"))
}

@Test
func codexContextOverflowRecoveryRunsOnlyOnce() async throws {
  let transport = CodexOverflowTransport(responseBodies: [
    codexToolCallResponse,
    codexContextErrorResponse,
    codexContextErrorResponse,
  ])
  let user = ScribeLLM.Components.Schemas.ChatMessage(role: .user, content: .case1("read image"))

  let (_, termination) = try await runCodexAgentLoop(
    promptMessages: [user],
    context: AgentContext(messages: []),
    config: codexOverflowConfig(transport: transport),
    emit: { _ in },
    logger: codexOverflowLogger,
    abortObserver: AbortNotifier())

  #expect(transport.requests().count == 3)
  guard case .error(let description) = termination else {
    Issue.record("Expected the second overflow to end the turn")
    return
  }
  #expect(description.contains("context_length_exceeded"))
}

@Test
func contextLengthRecognitionIncludesCodexStreamErrors() {
  #expect(isContextLengthError(.generic(
    "Your input exceeds the context window (code: context_length_exceeded)")))
  #expect(isContextLengthError(.generic(
    "Request payload exceeds the limit (code: input_too_large)")))
  #expect(!isContextLengthError(.generic("Image could not be processed")))
}
