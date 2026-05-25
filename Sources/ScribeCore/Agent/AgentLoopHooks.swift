import Foundation
import ScribeLLM


/// Optional callbacks invoked by the agent loop at well-defined boundaries.
///
/// All hooks default to pass-through behavior. Embedders use them for
/// context pruning, tool approval gates, post-processing, and graceful
/// stop after compaction without subclassing ``ScribeAgent``.
public struct AgentLoopHooks: Sendable {

  /// Transform the message list before each LLM request — prune history,
  /// inject external context, strip UI-only entries, etc.
  public var transformContext:
    @Sendable ([Components.Schemas.ChatMessage]) async -> [Components.Schemas.ChatMessage]

  /// Inspect or rewrite a tool call before execution. Return ``BeforeToolCallDecision/block(reason:)``
  /// to reject the call without running the tool.
  public var beforeToolCall: @Sendable (ToolInvocation) async -> BeforeToolCallDecision

  /// Post-process a tool result. Set ``AfterToolCallDecision/terminate`` to
  /// end the loop after this tool completes.
  public var afterToolCall:
    @Sendable (ToolInvocation, ToolResult) async -> AfterToolCallDecision

  /// Adjust model / reasoning / temperature before each LLM round.
  public var prepareNextTurn:
    @Sendable (Int, [Components.Schemas.ChatMessage]) async -> NextTurnOverrides

  /// Return `true` to stop gracefully after an assistant round completes
  /// without tool calls (e.g. after compaction injected a summary).
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


/// Outcome of a ``AgentLoopHooks/beforeToolCall`` hook.
public enum BeforeToolCallDecision: Sendable, Equatable {
  /// Run the tool (optionally with rewritten arguments).
  case proceed(ToolInvocation)
  /// Skip execution and surface a JSON error to the model.
  case block(reason: String)
}


/// Outcome of a ``AgentLoopHooks/afterToolCall`` hook.
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


/// Per-round overrides returned by ``AgentLoopHooks/prepareNextTurn``.
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
