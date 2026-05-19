import SystemPackage
import Foundation
import Testing

@testable import ScribeCore

@Suite
struct ToolRunnerRouterTests {
  @Test func unknownToolThrowsTypedError() async throws {
    let registry = ToolRegistry(tools: [ShellTool(), ReadFileTool(), WriteFileTool(), EditFileTool()], log: toolRunnerTestLogger)
    do {
      _ = try await registry.run(
        name: "not_a_registered_tool", arguments: "{}", workingDirectory: FilePath("/tmp"),
        log: toolRunnerTestLogger,
        abortObserver: AbortNotifier())
      #expect(Bool(false), "expected ScribeError.toolUnknown")
    } catch let error as ScribeError {
      guard case .toolUnknown(let name) = error else {
        #expect(Bool(false), "expected .toolUnknown, got \(error)")
        return
      }
      #expect(name == "not_a_registered_tool")
    } catch {
      #expect(Bool(false), "unexpected error type: \(error)")
    }
  }
}
