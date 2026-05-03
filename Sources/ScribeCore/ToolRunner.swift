import Foundation

/// Entry point for tool execution, created in the CLI so custom tools can be
/// registered before the agent loop starts.
public struct ToolRunner: Sendable {
  private let executor: ToolExecutor

  public init(tools: [any ScribeTool]) {
    self.executor = ToolExecutor(registry: ToolRegistry(tools: tools))
  }

  /// Entry point for the OpenAPI tool loop.
  public func run(name: String, argumentsJSON: String) async -> String {
    await executor.run(name: name, argumentsJSON: argumentsJSON)
  }
}
