import Foundation
import Logging
import OpenAPIRuntime
import ScribeLLM
import SystemPackage

public struct ToolAttachment: Sendable {
  public let mimeType: String
  public let base64: String
  public let filename: String?
  public let sourcePath: String?

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

  public var dataUri: String { "data:\(mimeType);base64,\(base64)" }
}

public struct ToolResult: Sendable {

  public let text: String

  public let attachments: [ToolAttachment]

  public let warnings: [String]

  public init(text: String, attachments: [ToolAttachment] = [], warnings: [String] = []) {
    self.text = text
    self.attachments = attachments
    self.warnings = warnings
  }
}

public protocol AttachableToolResult {
  var toolAttachments: [ToolAttachment] { get }

  /// Compact tool output sent back to the model alongside the attachments.
  /// Use this to keep large attachment payloads (for example base64 image data)
  /// out of ordinary tool messages, where they would otherwise be duplicated.
  var attachmentToolResultText: String? { get }
}

extension AttachableToolResult {
  public var attachmentToolResultText: String? { nil }
}

public protocol WarnableToolResult {
  var toolWarnings: [String] { get }
}

extension ToolResult {

  public static func text(_ string: String) -> ToolResult {
    ToolResult(text: string)
  }
}

public protocol ScribeTool: Sendable {

  static var name: String { get }

  static var description: String { get }

  static var parameters: [ScribeToolParameter] { get }

  static var promptHint: String? { get }

  func run(arguments: String, workingDirectory: FilePath, logger: Logger) async throws -> Encodable
}

extension ScribeTool {

  package static func toChatTool(logger: Logger) -> Components.Schemas.ChatTool {
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
      logger.warning(
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

public enum ScribeToolParameterType: String, Sendable {
  case string
  case integer
  case boolean
  case number
  case object
  case array
}

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
