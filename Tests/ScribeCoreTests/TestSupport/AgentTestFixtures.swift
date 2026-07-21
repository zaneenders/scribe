import Foundation
import Logging
import ScribeCore
import ScribeLLM
import SystemPackage

// MARK: - Logger

let testLogger = Logger(label: "test")

// MARK: - AbortObserver

/// An abort observer that never aborts and never signals.
struct NoOpAbortObserver: AbortObserver {
    func isAborted() -> Bool { false }
    func signals() -> AsyncStream<Void> { AsyncStream { $0.finish() } }
}

// MARK: - Tool Executor

/// A no-op tool executor that returns an empty result.
struct NoOpToolExecutor: ToolExecutor {
    func execute(
        _ invocation: ToolInvocation,
        workingDirectory: FilePath,
        logger: Logger,
        abort: any AbortObserver
    ) async throws -> ToolResult {
        ToolResult(text: "")
    }
}

// MARK: - Test Tools

struct FakeTool: ScribeTool {
    static var name: String { "fake_tool" }
    static var description: String { "A fake tool for testing." }
    static var parameters: [ScribeToolParameter] { [] }
    static var promptHint: String? { nil }
    struct Result: Encodable { let ok = true }
    func run(arguments: String, workingDirectory: FilePath, logger: Logger) async throws -> Encodable {
        _ = logger
        return Result()
    }
}

struct FailingTool: ScribeTool {
    static var name: String { "failing_tool" }
    static var description: String { "Throws a generic error." }
    static var parameters: [ScribeToolParameter] { [] }
    static var promptHint: String? { nil }
    struct Result: Encodable { let ok = true }
    func run(arguments: String, workingDirectory: FilePath, logger: Logger) async throws -> Encodable {
        _ = logger
        struct GenericError: Error {}
        throw GenericError()
    }
}
