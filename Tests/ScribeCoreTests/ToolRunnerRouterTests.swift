import Foundation
import ScribeCore
import Testing

@Suite
struct ToolRunnerRouterTests {
  @Test func unknownToolThrowsTypedError() async throws {
    let registry = ToolRegistry(tools: [ShellTool(), ReadFileTool(), WriteFileTool(), EditFileTool()])
    do {
      _ = try await registry.run(
        name: "not_a_registered_tool", arguments: "{}", workingDirectory: ScribeFilePath("/tmp"), abortVia: { false })
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
