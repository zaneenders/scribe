import Foundation

public struct ToolRunner: Sendable {
  public init() {}

  private let executor = ToolExecutor(
    registry: ToolRegistry(tools: [
      ShellTool(),
      ReadFileTool(),
      WriteFileTool(),
      EditFileTool(),
    ]))

  /// Entry point for the OpenAPI tool loop.
  public func run(name: String, argumentsJSON: String) async -> String {
    await executor.run(name: name, argumentsJSON: argumentsJSON)
  }
}
