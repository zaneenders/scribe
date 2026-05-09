import Foundation

// MARK: - InlineTool

/// A ``ScribeTool`` defined entirely at the call site — no separate type needed.
///
/// Use ``InlineTool`` when you want a one-off tool without declaring a dedicated
/// struct.  For reusable tools, prefer a named type that conforms to ``ScribeTool``.
///
/// ```swift
/// let myTool = InlineTool(
///   name: "greet",
///   description: "Returns a greeting.",
///   parameters: [
///     ScribeToolParameter(name: "name", type: .string, description: "Who to greet.")
///   ],
///   promptHint: nil
/// ) { arguments in
///   let obj = try ToolArgumentParsing.parseJSONObject(arguments)
///   let name = try ToolArgumentParsing.string(obj["name"], field: "name")
///   struct Result: Encodable { let ok = true; let greeting: String }
///   return Result(greeting: "Hello, \(name)!")
/// }
/// ```
public struct InlineTool: ScribeTool {
  public let name: String
  public let description: String
  public let parameters: [ScribeToolParameter]
  public let promptHint: String?

  private let _run: @Sendable (String) async throws -> Encodable

  /// Creates an inline tool.
  ///
  /// - Parameters:
  ///   - name: The tool name exposed to the LLM.
  ///   - description: Short description the LLM sees.
  ///   - parameters: JSON Schema parameter definitions.
  ///   - promptHint: Optional hint injected into the system prompt.
  ///   - run: The execution closure, receiving JSON-encoded arguments and
  ///     returning an `Encodable` result.
  public init(
    name: String,
    description: String,
    parameters: [ScribeToolParameter] = [],
    promptHint: String? = nil,
    run: @escaping @Sendable (String) async throws -> Encodable
  ) {
    self.name = name
    self.description = description
    self.parameters = parameters
    self.promptHint = promptHint
    self._run = run
  }

  public func run(arguments: String) async throws -> Encodable {
    try await _run(arguments)
  }
}
