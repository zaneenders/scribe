import Foundation

/// Executes tool calls by delegating to a ``ToolRegistry``.
///
/// `ToolExecutor` is intentionally a thin wrapper today, but it is a deliberate architectural
/// boundary between ``AgentLoop`` (orchestration) and ``ToolRegistry`` (implementation). The
/// three reasons for keeping the seam are:
///
/// 1. **Replaceable boundaries.** `AgentLoop` depends on `ToolExecutor`, not `ToolRegistry`.
///    If you later want a `SandboxedToolExecutor`, `LoggingToolExecutor`, or a
///    `CachedToolExecutor`, you swap the executor without touching the loop.
///
/// 2. **Test injection already works.** Tests inject a fake `ToolRegistry` (with `FakeTool`)
///    into a real `ToolExecutor`, then pass that to `AgentLoop`. This proves the seam is
///    useful even though the executor is currently a pass-through.
///
/// 3. **No leakage.** `ToolRegistry` knows about `ScribeTool` protocol internals, JSON
///    encoding strategies, and error formatting. `AgentLoop` does not need to know any of
///    that; it only needs something that can execute a tool by name and return JSON.
///
/// If after several months the executor has not grown any behavior (logging, metrics,
/// sandboxing, caching), it may be worth folding it back into `AgentLoop` and having the
/// loop accept a `ToolRegistry` directly.
public struct ToolExecutor: Sendable {
  private let registry: ToolRegistry

  public init(registry: ToolRegistry) {
    self.registry = registry
  }

  /// Entry point for the OpenAPI tool loop.
  public func run(name: String, argumentsJSON: String) async -> String {
    await registry.run(name: name, arguments: argumentsJSON)
  }
}
