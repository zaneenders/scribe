import Foundation
import ScribeLLM

public enum ScribeContentPart: Sendable, Codable, Hashable {
  case text(String)
  case image(url: String, detail: String?)

  enum CodingKeys: String, CodingKey {
    case type
    case text
    case imageUrl = "image_url"
  }

  struct ImageUrlPayload: Codable, Hashable, Sendable {
    var url: String
    var detail: String?
    enum CodingKeys: String, CodingKey {
      case url
      case detail
    }
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let type = try container.decode(String.self, forKey: .type)
    switch type {
    case "text":
      let text = try container.decode(String.self, forKey: .text)
      self = .text(text)
    case "image_url":
      let payload = try container.decode(ImageUrlPayload.self, forKey: .imageUrl)
      self = .image(url: payload.url, detail: payload.detail)
    default:
      throw DecodingError.dataCorruptedError(
        forKey: .type,
        in: container,
        debugDescription: "Unknown content part type: \(type)")
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .text(let text):
      try container.encode("text", forKey: .type)
      try container.encode(text, forKey: .text)
    case .image(let url, let detail):
      try container.encode("image_url", forKey: .type)
      let payload = ImageUrlPayload(url: url, detail: detail)
      try container.encode(payload, forKey: .imageUrl)
    }
  }
}

public struct ScribeMessage: Sendable, Codable, Hashable {

  public enum Role: String, Sendable, Codable, Hashable, CaseIterable {
    case system
    case user
    case assistant
    case tool
  }

  public var role: Role
  public var contentParts: [ScribeContentPart]
  public var content: String {
    contentParts.compactMap { if case .text(let t) = $0 { t } else { nil } }.joined()
  }
  public var name: String?
  public var toolCalls: [ScribeToolCall]?
  public var toolCallId: String?
  public var reasoning: String?

  public init(
    role: Role,
    content: String = "",
    contentParts: [ScribeContentPart]? = nil,
    name: String? = nil,
    toolCalls: [ScribeToolCall]? = nil,
    toolCallId: String? = nil,
    reasoning: String? = nil
  ) {
    self.role = role
    if let parts = contentParts {
      self.contentParts = parts
    } else if !content.isEmpty {
      self.contentParts = [.text(content)]
    } else {
      self.contentParts = []
    }
    self.name = name
    self.toolCalls = toolCalls
    self.toolCallId = toolCallId
    self.reasoning = reasoning
  }

  enum CodingKeys: String, CodingKey {
    case role
    case content
    case name
    case toolCalls = "tool_calls"
    case toolCallId = "tool_call_id"
    case reasoning = "reasoning_content"
  }

  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    self.role = try c.decode(Role.self, forKey: .role)
    self.name = try c.decodeIfPresent(String.self, forKey: .name)
    self.toolCallId = try c.decodeIfPresent(String.self, forKey: .toolCallId)
    self.reasoning = try c.decodeIfPresent(String.self, forKey: .reasoning)

    if let parts = try? c.decode([ScribeContentPart].self, forKey: .content) {
      self.contentParts = parts
    } else if let text = try c.decodeIfPresent(String.self, forKey: .content), !text.isEmpty {
      self.contentParts = [.text(text)]
    } else {
      self.contentParts = []
    }

    if let wires = try c.decodeIfPresent([ScribeToolCall.Wire].self, forKey: .toolCalls) {
      self.toolCalls = wires.compactMap(ScribeToolCall.init(wire:))
    } else {
      self.toolCalls = nil
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(role, forKey: .role)
    if contentParts.count == 1, case .text(let t) = contentParts[0] {
      try c.encode(t, forKey: .content)
    } else if contentParts.isEmpty {
      try c.encode("", forKey: .content)
    } else {
      try c.encode(contentParts, forKey: .content)
    }
    try c.encodeIfPresent(name, forKey: .name)
    try c.encodeIfPresent(toolCallId, forKey: .toolCallId)
    try c.encodeIfPresent(reasoning, forKey: .reasoning)
    if let calls = toolCalls {
      let wires = calls.map { $0.toWire() }
      try c.encode(wires, forKey: .toolCalls)
    }
  }
}

public struct ScribeToolCall: Sendable, Codable, Hashable {
  public var id: String
  public var name: String
  public var arguments: String

  public init(id: String, name: String, arguments: String) {
    self.id = id
    self.name = name
    self.arguments = arguments
  }

  fileprivate struct Wire: Codable, Hashable {
    var id: String?
    var _type: String?
    var function: Function?
    struct Function: Codable, Hashable {
      var name: String?
      var arguments: String?
    }
    enum CodingKeys: String, CodingKey {
      case id
      case _type = "type"
      case function
    }
  }

  fileprivate init?(wire: Wire) {
    guard let id = wire.id, let fn = wire.function, let name = fn.name else { return nil }
    self.init(id: id, name: name, arguments: fn.arguments ?? "")
  }

  fileprivate func toWire() -> Wire {
    Wire(id: id, _type: "function", function: .init(name: name, arguments: arguments))
  }

  public init(from decoder: any Decoder) throws {
    let wire = try Wire(from: decoder)
    guard let bridged = ScribeToolCall(wire: wire) else {
      throw DecodingError.dataCorruptedError(
        in: try decoder.singleValueContainer(),
        debugDescription: "Tool call missing id/function.name")
    }
    self = bridged
  }

  public func encode(to encoder: any Encoder) throws {
    try toWire().encode(to: encoder)
  }
}

extension ScribeMessage {

  package init(_ chatMessage: Components.Schemas.ChatMessage) {
    let role: Role = {
      switch chatMessage.role {
      case .system: return .system
      case .user: return .user
      case .assistant: return .assistant
      case .tool: return .tool
      }
    }()
    let calls: [ScribeToolCall]? = chatMessage.toolCalls?.compactMap { c in
      guard let id = c.id, let fn = c.function, let name = fn.name else { return nil }
      return ScribeToolCall(id: id, name: name, arguments: fn.arguments ?? "")
    }

    let contentParts: [ScribeContentPart]
    switch chatMessage.content {
    case .case1(let text):
      contentParts = text.isEmpty ? [] : [.text(text)]
    case .case2(let parts):
      contentParts = parts.map { part in
        switch part {
        case .text(let p): return .text(p.text)
        case .imageUrl(let p): return .image(url: p.imageUrl.url, detail: p.imageUrl.detail?.rawValue)
        }
      }
    case .none:
      contentParts = []
    }

    self.init(
      role: role,
      contentParts: contentParts,
      name: chatMessage.name,
      toolCalls: calls?.isEmpty == true ? nil : calls,
      toolCallId: chatMessage.toolCallId,
      reasoning: chatMessage.reasoningContent
    )
  }

  package func toChatMessage() -> Components.Schemas.ChatMessage {
    let role: Components.Schemas.ChatMessage.RolePayload = {
      switch self.role {
      case .system: return .system
      case .user: return .user
      case .assistant: return .assistant
      case .tool: return .tool
      }
    }()

    let contentPayload: Components.Schemas.ChatMessage.ContentPayload?
    if contentParts.isEmpty {
      contentPayload = nil
    } else if contentParts.count == 1, case .text(let t) = contentParts[0] {
      contentPayload = t.isEmpty ? nil : .case1(t)
    } else {
      let chatParts = contentParts.map { part -> Components.Schemas.ChatContentPart in
        switch part {
        case .text(let text):
          return .text(.init(_type: .text, text: text))
        case .image(let url, let detail):
          let detailPayload: Components.Schemas.ChatImageContentPart.ImageUrlPayload.DetailPayload? = {
            guard let d = detail else { return nil }
            switch d {
            case "low": return .low
            case "high": return .high
            default: return .auto
            }
          }()
          return .imageUrl(.init(
            _type: .imageUrl,
            imageUrl: .init(url: url, detail: detailPayload)
          ))
        }
      }
      contentPayload = .case2(chatParts)
    }

    let calls = toolCalls?.map { tc in
      Components.Schemas.AssistantToolCall(
        id: tc.id,
        _type: "function",
        function: .init(name: tc.name, arguments: tc.arguments)
      )
    }
    return Components.Schemas.ChatMessage(
      role: role,
      content: contentPayload,
      name: name,
      toolCalls: calls,
      toolCallId: toolCallId,
      reasoningContent: reasoning
    )
  }
}

extension Array where Element == ScribeMessage {
  package func toWireMessages() -> [Components.Schemas.ChatMessage] {
    map { $0.toChatMessage() }
  }

  package func toChatMessages() -> [Components.Schemas.ChatMessage] {
    toWireMessages()
  }
}

extension Array where Element == Components.Schemas.ChatMessage {
  package func toScribeMessages() -> [ScribeMessage] {
    map(ScribeMessage.init)
  }
}
