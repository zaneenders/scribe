import Foundation
import ScribeLLM

enum BeforeToolCallDecision: Sendable, Equatable {
  case proceed(ToolInvocation)
  case block(reason: String)
}

struct AfterToolCallDecision: Sendable {
  var result: ToolResult
  var terminate: Bool

  init(result: ToolResult, terminate: Bool = false) {
    self.result = result
    self.terminate = terminate
  }

  static func passThrough(_ result: ToolResult) -> Self {
    AfterToolCallDecision(result: result, terminate: false)
  }
}

struct AgentLoopHooks: Sendable {

  var onMessagesCommitted: @Sendable ([ScribeMessage]) async throws -> Void

  var beforeToolCall: @Sendable (ToolInvocation) async -> BeforeToolCallDecision

  var afterToolCall: @Sendable (ToolInvocation, ToolResult) async -> AfterToolCallDecision

  init(
    onMessagesCommitted: @escaping @Sendable ([ScribeMessage]) async throws -> Void = { _ in },
    beforeToolCall: @escaping @Sendable (ToolInvocation) async -> BeforeToolCallDecision = {
      .proceed($0)
    },
    afterToolCall: @escaping @Sendable (ToolInvocation, ToolResult) async -> AfterToolCallDecision = {
      _, result in .passThrough(result)
    }
  ) {
    self.onMessagesCommitted = onMessagesCommitted
    self.beforeToolCall = beforeToolCall
    self.afterToolCall = afterToolCall
  }
}
