import Foundation

public struct ToolRunner: Sendable {
  public init() {}

  private let registry = ToolRegistry(tools: [
    ShellTool(),
    ReadFileTool(),
    WriteFileTool(),
    EditFileTool(),
  ])

  /// Entry point for the OpenAPI tool loop.
  public func run(name: String, argumentsJSON: String) async -> String {
    await registry.run(name: name, arguments: argumentsJSON)
  }
}
