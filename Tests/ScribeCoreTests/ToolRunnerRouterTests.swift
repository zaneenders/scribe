import Foundation
import ScribeCore
import Testing

@Suite
struct ToolRunnerRouterTests {
  @Test func unknownToolReturnsStructuredFailure() async throws {
    let registry = ToolRegistry(tools: [ShellTool(), ReadFileTool(), WriteFileTool(), EditFileTool()])
    let json = await registry.run(name: "not_a_registered_tool", arguments: "{}")
    let fail = try decodeFail(json)
    #expect(fail.ok == false)
    #expect(fail.error?.contains("unknown tool") == true)
  }
}
