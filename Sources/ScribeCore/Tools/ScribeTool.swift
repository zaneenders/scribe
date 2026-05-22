import SystemPackage
import Foundation
import Logging
import OpenAPIRuntime
import ScribeLLM

// MARK: - ToolAttachment / ToolResult

/// Media content returned by a tool — images, PDFs, audio, etc.
///
/// When a tool produces an attachment, the agent loop injects a synthetic
/// user message carrying the attachment so the model can view it on the next
/// turn (OpenAI-compatible APIs only accept string content in tool results).
public struct ToolAttachment: Sendable {
  public let mimeType: String  // e.g. "image/png", "application/pdf"
  public let base64: String    // base64-encoded bytes
  public let filename: String? // optional display name
  public let sourcePath: String? // optional source path

  public init(
    mimeType: String,
    base64: String,
    filename: String? = nil,
    sourcePath: String? = nil
  ) {
    self.mimeType = mimeType
    self.base64 = base64
    self.filename = filename
    self.sourcePath = sourcePath
  }

  /// "data:\(mimeType);base64,\(base64)" data URI for use in `ScribeContentPart.image(url:)`.
  public var dataUri: String { "data:\(mimeType);base64,\(base64)" }
}

/// Bundled tool output: JSON/text content for the tool-result message plus
/// optional attachments that get injected as synthetic user messages.
public struct ToolResult: Sendable {
  /// JSON/text output to place in the `role: .tool` message.
  public let text: String
  /// Attachments to inject as follow-up user messages.
  public let attachments: [ToolAttachment]
  /// User-visible warnings to surface as `AgentEvent.tool(.warning(_))`.
  public let warnings: [String]

  public init(text: String, attachments: [ToolAttachment] = [], warnings: [String] = []) {
    self.text = text
    self.attachments = attachments
    self.warnings = warnings
  }
}

/// Opt-in protocol for tool result types that carry attachments.
///
/// Conform a tool's `Encodable` result type to this protocol and return
/// non-empty ``toolAttachments``. ``ToolRegistry`` detects the conformance
/// and builds a ``ToolResult`` with the attachments, avoiding the old
/// `isImage` / JSON-parse dance in the agent loop.
public protocol AttachableToolResult {
  var toolAttachments: [ToolAttachment] { get }
}

/// Opt-in protocol for tool result types that carry user-visible warnings.
///
/// ``ToolRegistry`` detects the conformance and populates ``ToolResult/warnings``,
/// which ``AgentLoop`` emits as ``AgentEvent`` `.tool(.warning(_))` entries.
public protocol WarnableToolResult {
  var toolWarnings: [String] { get }
}

// MARK: - Tool executor result helper

extension ToolResult {
  /// Create a text-only `ToolResult` suitable for error / unknown-tool reporting.
  public static func text(_ string: String) -> ToolResult {
    ToolResult(text: string)
  }
}

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
  func run(arguments: String, workingDirectory: FilePath, log: Logger) async throws -> Encodable
}

// MARK: - ScribeTool → ChatTool conversion

extension ScribeTool {
  /// Converts this tool's schema into the `ChatTool` form the LLM API
  /// expects. `package` so the wire shape stays inside ScribeCore — only
  /// `ScribeAgent` and `ToolRegistry` need to build the request payload.
  package static func toChatTool(log: Logger) -> Components.Schemas.ChatTool {
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
      log.warning(
        "tool.chatTool.payload.invalid",
        metadata: [
          "tool": "\(name)",
          "err": "\(String(describing: error))",
        ])
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
