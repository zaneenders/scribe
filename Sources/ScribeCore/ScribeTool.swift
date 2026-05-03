import Foundation

/// A tool that can be registered and invoked by the agent.
public protocol ScribeTool: Sendable {
  /// The tool name as exposed to the LLM (e.g. `"shell"`, `"read_file"`).
  static var name: String { get }

  /// Execute the tool with the given JSON-encoded arguments.
  ///
  /// - Returns: An `Encodable` value that the registry will serialize as JSON.
  ///   The value should include an `ok: true` field so the encoded response is
  ///   self-describing.
  func run(arguments: String) async throws -> Encodable
}
