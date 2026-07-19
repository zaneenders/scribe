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

  /// Hard limits for text inserted into model context. Attachments are carried separately.
  public static let maxTextBytes = 128 * 1024
  public static let maxTextCharacters = 128_000

  public let text: String

  public let attachments: [ToolAttachment]

  public let warnings: [String]

  public let textWasTruncated: Bool

  public init(text: String, attachments: [ToolAttachment] = [], warnings: [String] = []) {
    let bounded = Self.boundedText(text)
    self.text = bounded.text
    self.attachments = attachments
    self.warnings =
      bounded.truncated
      ? warnings + [
        "Tool result exceeded the global 128 KiB / 128,000-character limit and was truncated."
      ]
      : warnings
    self.textWasTruncated = bounded.truncated
  }

  private static func boundedText(_ text: String) -> (text: String, truncated: Bool) {
    let originalBytes = text.utf8.count
    let originalCharacters = text.count
    guard originalBytes > maxTextBytes || originalCharacters > maxTextCharacters else {
      return (text, false)
    }

    // Keep the replacement valid JSON so every tool and transcript consumer can handle it.
    // The preview budget is reduced until JSON escaping and metadata also fit both ceilings.
    let characters = Array(text.prefix(maxTextCharacters))
    var low = 0
    var high = characters.count
    var best = truncationEnvelope(
      preview: "", originalBytes: originalBytes, originalCharacters: originalCharacters)

    while low <= high {
      let middle = low + (high - low) / 2
      let candidate = truncationEnvelope(
        preview: String(characters.prefix(middle)),
        originalBytes: originalBytes,
        originalCharacters: originalCharacters)
      if candidate.utf8.count <= maxTextBytes && candidate.count <= maxTextCharacters {
        best = candidate
        low = middle + 1
      } else {
        high = middle - 1
      }
    }
    return (best, true)
  }

  private static func truncationEnvelope(
    preview: String,
    originalBytes: Int,
    originalCharacters: Int
  ) -> String {
    let payload: [String: Any] = [
      "tool_result_truncated": true,
      "truncation_reason": "global_tool_result_limit",
      "original_bytes": originalBytes,
      "original_characters": originalCharacters,
      "max_bytes": maxTextBytes,
      "max_characters": maxTextCharacters,
      "content_preview": preview,
    ]
    guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else {
      return #"{"tool_result_truncated":true,"truncation_reason":"global_tool_result_limit"}"#
    }
    return String(decoding: data, as: UTF8.self)
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
