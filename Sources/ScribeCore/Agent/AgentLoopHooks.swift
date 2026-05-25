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

struct NextTurnOverrides: Sendable, Equatable {
  var model: String?
  var reasoningEnabled: Bool?
  var temperature: Double?

  init(
    model: String? = nil,
    reasoningEnabled: Bool? = nil,
    temperature: Double? = nil
  ) {
    self.model = model
    self.reasoningEnabled = reasoningEnabled
    self.temperature = temperature
  }

  static let none = NextTurnOverrides()
}

struct AgentLoopHooks: Sendable {

  var transformContext: @Sendable ([Components.Schemas.ChatMessage]) async -> [Components.Schemas.ChatMessage]

  var beforeToolCall: @Sendable (ToolInvocation) async -> BeforeToolCallDecision

  var afterToolCall: @Sendable (ToolInvocation, ToolResult) async -> AfterToolCallDecision

  var prepareNextTurn: @Sendable (Int, [Components.Schemas.ChatMessage]) async -> NextTurnOverrides

  var shouldStopAfterTurn: @Sendable (Int) async -> Bool

  init(
    transformContext:
      @escaping @Sendable ([Components.Schemas.ChatMessage]) async
      -> [Components.Schemas.ChatMessage] = { $0 },
    beforeToolCall: @escaping @Sendable (ToolInvocation) async -> BeforeToolCallDecision = {
      .proceed($0)
    },
    afterToolCall: @escaping @Sendable (ToolInvocation, ToolResult) async -> AfterToolCallDecision = {
      _, result in .passThrough(result)
    },
    prepareNextTurn:
      @escaping @Sendable (Int, [Components.Schemas.ChatMessage]) async
      -> NextTurnOverrides = { _, _ in .none },
    shouldStopAfterTurn: @escaping @Sendable (Int) async -> Bool = { _ in false }
  ) {
    self.transformContext = transformContext
    self.beforeToolCall = beforeToolCall
    self.afterToolCall = afterToolCall
    self.prepareNextTurn = prepareNextTurn
    self.shouldStopAfterTurn = shouldStopAfterTurn
  }

  static let `default` = AgentLoopHooks()
}
