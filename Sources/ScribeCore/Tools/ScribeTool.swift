import Foundation
import Logging
import OpenAPIRuntime
import ScribeLLM

// MARK: - Tool protocol

/// A tool that can be registered and invoked by the agent.
///
/// Conformances provide both the LLM-facing schema and the runtime execution
/// so a single type is the source of truth for a tool.
public protocol ScribeTool: Sendable {
  /// The tool name as exposed to the LLM (e.g. `"shell"`, `"read_file"`).
  static var name: String { get }

  /// Short description the LLM sees when deciding whether to call this tool.
  static var description: String { get }

  /// JSON Schema parameters the tool accepts.
  static var parameters: [ScribeToolParameter] { get }

  /// Optional hint injected into the system prompt (e.g. pagination guidance).
  static var promptHint: String? { get }

  /// Execute the tool with the given JSON-encoded arguments and explicit working directory.
  ///
  /// - Parameters:
  ///   - arguments: JSON-encoded arguments string from the LLM.
  ///   - workingDirectory: The absolute working directory for path resolution.
  /// - Returns: An `Encodable` value that the registry will serialize as JSON.
  func run(arguments: String, workingDirectory: ScribeFilePath) async throws -> Encodable
}

// MARK: - ScribeTool → ChatTool conversion

extension ScribeTool {
  /// Converts this tool's schema into the `ChatTool` form the LLM API
  /// expects. `package` so the wire shape stays inside ScribeCore — only
  /// `ScribeAgent` and `ToolRegistry` need to build the request payload.
  package static func toChatTool() -> Components.Schemas.ChatTool {
    var props: [String: (any Sendable)?] = [:]
    var required: [String] = []
    for p in parameters {
      props[p.name] = ["type": p.type.rawValue, "description": p.description] as [String: (any Sendable)?]
      if p.required { required.append(p.name) }
    }
    let payload: [String: (any Sendable)?] = [
      "type": "object",
      "properties": props,
      "required": required,
    ]
    let container: OpenAPIObjectContainer
    do {
      container = try OpenAPIObjectContainer(unvalidatedValue: payload)
    } catch {
      let log = Logger(label: "scribe.tool")
      log.warning(
        """
        event=tool.chatTool.payload.invalid \
        tool=\(name) \
        err="\(String(describing: error))"
        """)
      container = OpenAPIObjectContainer()
    }
    return Components.Schemas.ChatTool(
      _type: .function,
      function: .init(
        name: name,
        description: description,
        parameters: .init(additionalProperties: container)
      )
    )
  }
}

// MARK: - Tool parameter

/// JSON Schema type for a tool parameter.
public enum ScribeToolParameterType: String, Sendable {
  case string
  case integer
  case boolean
  case number
  case object
  case array
}

/// A single parameter in a tool's JSON Schema.
public struct ScribeToolParameter: Sendable {
  public let name: String
  public let type: ScribeToolParameterType
  public let description: String
  public let required: Bool

  public init(name: String, type: ScribeToolParameterType, description: String, required: Bool = true) {
    self.name = name
    self.type = type
    self.description = description
    self.required = required
  }
}
