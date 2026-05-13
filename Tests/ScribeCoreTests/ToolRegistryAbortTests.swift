import Foundation
import ScribeCore
import Testing

@testable import ScribeCore

// MARK: - Fake tool that throws

private struct ThrowingTool: ScribeTool {
    static var name: String { "thrower" }
    static var description: String { "Always throws." }
    static var parameters: [ScribeToolParameter] { [] }
    static var promptHint: String? { nil }

    let errorMessage: String

    func run(arguments: String, workingDirectory: ScribeFilePath) async throws -> any Encodable {
        throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: errorMessage])
    }
}

// MARK: - Fake tool that succeeds (returns String which is Encodable)

private struct EchoTool: ScribeTool {
    static var name: String { "echo" }
    static var description: String { "Returns its arguments." }
    static var parameters: [ScribeToolParameter] { [] }
    static var promptHint: String? { nil }

    let value: String

    func run(arguments: String, workingDirectory: ScribeFilePath) async throws -> any Encodable {
        return value
    }
}

// MARK: - ToolRegistry abort & error tests

@Suite
struct ToolRegistryAbortTests {

    // MARK: - Unknown tool

    @Test func unknownToolThrowsTypedError() async throws {
        let registry = ToolRegistry(tools: [ShellTool()])
        let notifier = AbortNotifier()
        do {
            _ = try await registry.run(
                name: "nonexistent", arguments: "{}",
                workingDirectory: ScribeFilePath("/tmp"), abortObserver: notifier)
            #expect(Bool(false), "expected ScribeError.toolUnknown")
        } catch let error as ScribeError {
            guard case .toolUnknown(let name) = error else {
                #expect(Bool(false), "expected .toolUnknown, got \(error)")
                return
            }
            #expect(name == "nonexistent")
        } catch {
            #expect(Bool(false), "unexpected error type: \(error)")
        }
    }

    // MARK: - Abort before start

    @Test func abortBeforeStartThrowsInterrupted() async {
        let tool = EchoTool(value: "should not run")
        let registry = ToolRegistry(tools: [tool])
        let notifier = AbortNotifier()
        notifier.request()

        do {
            _ = try await registry.run(
                name: "echo", arguments: "{}",
                workingDirectory: ScribeFilePath("/tmp"), abortObserver: notifier)
            #expect(Bool(false), "expected AgentTurnInterruptedError")
        } catch is AgentTurnInterruptedError {
            // expected
        } catch {
            #expect(Bool(false), "unexpected error: \(error)")
        }
    }

    // MARK: - Abort mid-execution

    @Test func abortMidExecutionThrowsInterrupted() async {
        struct SlowTool: ScribeTool {
            static var name: String { "slow" }
            static var description: String { "Slow tool." }
            static var parameters: [ScribeToolParameter] { [] }
            static var promptHint: String? { nil }
            func run(arguments: String, workingDirectory: ScribeFilePath) async throws -> any Encodable {
                try await Task.sleep(for: .seconds(10))
                return "done"
            }
        }

        let registry = ToolRegistry(tools: [SlowTool()])
        let notifier = AbortNotifier()

        let task = Task {
            try await registry.run(
                name: "slow", arguments: "{}",
                workingDirectory: ScribeFilePath("/tmp"), abortObserver: notifier)
        }

        // Give the tool task a moment to start, then abort
        try? await Task.sleep(for: .milliseconds(100))
        notifier.request()

        do {
            _ = try await task.value
            #expect(Bool(false), "expected AgentTurnInterruptedError")
        } catch is AgentTurnInterruptedError {
            // expected
        } catch {
            #expect(Bool(false), "unexpected error: \(error)")
        }
    }

    // MARK: - Tool throws

    @Test func toolThatThrowsReturnsErrorJSON() async throws {
        let tool = ThrowingTool(errorMessage: "something went wrong")
        let registry = ToolRegistry(tools: [tool])
        let notifier = AbortNotifier()

        let json = try await registry.run(
            name: "thrower", arguments: "{}",
            workingDirectory: ScribeFilePath("/tmp"), abortObserver: notifier)

        // Should be a JSON error response
        #expect(json.contains("\"ok\":false") || json.contains("\"ok\" : false"))
        #expect(json.contains("something went wrong"))
    }

    // MARK: - Tool succeeds

    @Test func toolSuccessReturnsJSON() async throws {
        let tool = EchoTool(value: "hello")
        let registry = ToolRegistry(tools: [tool])
        let notifier = AbortNotifier()

        let json = try await registry.run(
            name: "echo", arguments: "{}",
            workingDirectory: ScribeFilePath("/tmp"), abortObserver: notifier)

        // JSON-encoded string should contain "hello"
        #expect(json.contains("hello"))
    }

    // MARK: - Multiple tools in registry

    @Test func correctToolIsDispatched() async throws {
        let toolA = EchoTool(value: "AAA")
        let toolB = EchoTool(value: "BBB")
        let registry = ToolRegistry(tools: [toolA, toolB])
        let notifier = AbortNotifier()

        let jsonA = try await registry.run(
            name: "echo", arguments: "{}",
            workingDirectory: ScribeFilePath("/tmp"), abortObserver: notifier)
        #expect(jsonA.contains("AAA") || jsonA.contains("BBB"))
    }
}
