import Foundation
import ScribeCore
import Testing

@Suite
struct ToolRunnerRouterTests {
  @Test func unknownToolReturnsStructuredFailure() async throws {
    let runner = ToolRunner(tools: [ShellTool(), ReadFileTool(), WriteFileTool(), EditFileTool()])
    let json = await runner.run(name: "not_a_registered_tool", argumentsJSON: "{}")
    let fail = try decodeFail(json)
    #expect(fail.ok == false)
    #expect(fail.error?.contains("unknown tool") == true)
  }
}
