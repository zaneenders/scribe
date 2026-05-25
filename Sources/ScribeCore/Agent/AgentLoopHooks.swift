import Foundation
import ScribeLLM

public struct AgentLoopHooks: Sendable {

  public var transformContext:
    @Sendable ([Components.Schemas.ChatMessage]) async -> [Components.Schemas.ChatMessage]

  public var beforeToolCall: @Sendable (ToolInvocation) async -> BeforeToolCallDecision

  public var afterToolCall:
    @Sendable (ToolInvocation, ToolResult) async -> AfterToolCallDecision

  public var prepareNextTurn:
    @Sendable (Int, [Components.Schemas.ChatMessage]) async -> NextTurnOverrides

  public var shouldStopAfterTurn: @Sendable (Int) async -> Bool

  public init(
    transformContext: @escaping @Sendable ([Components.Schemas.ChatMessage]) async
      -> [Components.Schemas.ChatMessage] = { $0 },
    beforeToolCall: @escaping @Sendable (ToolInvocation) async -> BeforeToolCallDecision = {
      .proceed($0)
    },
    afterToolCall: @escaping @Sendable (ToolInvocation, ToolResult) async -> AfterToolCallDecision = {
      .passThrough($1)
    },
    prepareNextTurn: @escaping @Sendable (Int, [Components.Schemas.ChatMessage]) async
      -> NextTurnOverrides = { _, _ in .none },
    shouldStopAfterTurn: @escaping @Sendable (Int) async -> Bool = { _ in false }
  ) {
    self.transformContext = transformContext
    self.beforeToolCall = beforeToolCall
    self.afterToolCall = afterToolCall
    self.prepareNextTurn = prepareNextTurn
    self.shouldStopAfterTurn = shouldStopAfterTurn
  }

  public static let `default` = AgentLoopHooks()
}

public enum BeforeToolCallDecision: Sendable, Equatable {

  case proceed(ToolInvocation)

  case block(reason: String)
}

public struct AfterToolCallDecision: Sendable {
  public var result: ToolResult
  public var terminate: Bool

  public init(result: ToolResult, terminate: Bool = false) {
    self.result = result
    self.terminate = terminate
  }

  public static func passThrough(_ result: ToolResult) -> Self {
    AfterToolCallDecision(result: result, terminate: false)
  }
}

public struct NextTurnOverrides: Sendable, Equatable {
  public var model: String?
  public var reasoningEnabled: Bool?
  public var temperature: Double?

  public init(
    model: String? = nil,
    reasoningEnabled: Bool? = nil,
    temperature: Double? = nil
  ) {
    self.model = model
    self.reasoningEnabled = reasoningEnabled
    self.temperature = temperature
  }

  public static let none = NextTurnOverrides()
}
