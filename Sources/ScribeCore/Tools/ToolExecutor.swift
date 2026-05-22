import SystemPackage
import Foundation
import Logging

// MARK: - ToolExecutor

/// Pluggable backend that resolves a single tool invocation to its
/// JSON-encoded output. Default impl: ``ToolRegistry``.
///
/// Embedded callers (server, sub-agent, sandbox runner) implement this
/// protocol to:
///
/// - **Approve** tool calls before they execute (human-in-the-loop).
/// - **Override** specific tools (e.g. swap the built-in `shell` for a
///   sandboxed remote shell).
/// - **Forward** invocations over the wire to another process or service.
/// - **Tag** invocations with extra metadata (auth, tenant, span ids).
///
/// The agent loop never inspects the executor beyond calling
/// ``execute(_:workingDirectory:abort:)``. It is the executor's job to:
///
/// 1. Return a JSON string the assistant can consume — even on tool
///    failure (a `{"ok": false, "error": "..."}` shape is the convention).
/// 2. Throw ``AgentTurnInterruptedError`` when `abort` fires so the loop
///    rolls back the in-flight round cleanly. Any other error is treated
///    as a tool failure and surfaced to the model as a JSON error string.
public protocol ToolExecutor: Sendable {
  func execute(
    _ invocation: ToolInvocation,
    workingDirectory: FilePath,
    log: Logger,
    abort: any AbortObserver
  ) async throws -> ToolResult
}
