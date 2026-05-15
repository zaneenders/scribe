import Foundation
import ScribeLLM

// MARK: - ScribeMessage

/// Transport-agnostic chat message used by Scribe's public agent API.
///
/// `ScribeMessage` is the lingua franca for embedders: it carries the same
/// shape as the OpenAI chat-completion `ChatMessage` (so on-disk JSONL and
/// HTTP request bodies round-trip cleanly), but it is **not** the generated
/// `Components.Schemas.ChatMessage` — that type belongs to the OpenAI wire
/// transport and is an implementation detail of ``ScribeLLM``. Defining a
/// thin in-Core message type lets us add Anthropic / Gemini transports
/// later (and gives session JSONL a stable schema that is forward-compatible
/// with non-OpenAI providers).
///
/// The Codable conformance uses snake_case keys (`tool_calls`,
/// `tool_call_id`, `reasoning_content`) so historic session files written
/// from the generated type continue to decode unchanged.
public struct ScribeMessage: Sendable, Codable, Hashable {

  /// Role of a chat message participant.
  public enum Role: String, Sendable, Codable, Hashable, CaseIterable {
    case system
    case user
    case assistant
    case tool
  }

  public var role: Role
  /// Plain-text content. Defaults to an empty string for assistant messages
  /// that exist purely to carry `toolCalls`. Empty content is encoded as
  /// `""` rather than omitted, matching OpenAI's behaviour for tool-calling
  /// assistant messages.
  public var content: String
  public var name: String?
  public var toolCalls: [ScribeToolCall]?
  public var toolCallId: String?
  /// Chain-of-thought from a prior assistant turn; some providers (e.g. DeepSeek
  /// thinking mode) require this to be echoed on follow-up requests unchanged.
  /// Maps to `reasoning_content` on the wire.
  public var reasoning: String?

  public init(
    role: Role,
    content: String = "",
    name: String? = nil,
    toolCalls: [ScribeToolCall]? = nil,
    toolCallId: String? = nil,
    reasoning: String? = nil
  ) {
    self.role = role
    self.content = content
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
    self.content = try c.decodeIfPresent(String.self, forKey: .content) ?? ""
    self.name = try c.decodeIfPresent(String.self, forKey: .name)
    self.toolCallId = try c.decodeIfPresent(String.self, forKey: .toolCallId)
    self.reasoning = try c.decodeIfPresent(String.self, forKey: .reasoning)
    if let wires = try c.decodeIfPresent([ScribeToolCall.Wire].self, forKey: .toolCalls) {
      self.toolCalls = wires.compactMap(ScribeToolCall.init(wire:))
    } else {
      self.toolCalls = nil
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(role, forKey: .role)
    try c.encode(content, forKey: .content)
    try c.encodeIfPresent(name, forKey: .name)
    try c.encodeIfPresent(toolCallId, forKey: .toolCallId)
    try c.encodeIfPresent(reasoning, forKey: .reasoning)
    if let calls = toolCalls {
      let wires = calls.map { $0.toWire() }
      try c.encode(wires, forKey: .toolCalls)
    }
  }
}

// MARK: - ScribeToolCall

/// A resolved tool call attached to an assistant message.
///
/// The on-wire OpenAI shape is `{ id, type: "function", function: { name, arguments } }`,
/// but Scribe's loop only ever produces `function` calls, so the public
/// surface flattens it to `(id, name, arguments)`. Conversion happens in
/// the Codable bridge below.
public struct ScribeToolCall: Sendable, Codable, Hashable {
  public var id: String
  public var name: String
  /// JSON-encoded arguments string (matches OpenAI's wire format — providers
  /// hand back the raw JSON the model generated).
  public var arguments: String

  public init(id: String, name: String, arguments: String) {
    self.id = id
    self.name = name
    self.arguments = arguments
  }

  // MARK: Codable bridge for the nested OpenAI shape

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

// MARK: - Bridge to / from Components.Schemas.ChatMessage

/// Internal conversions between ``ScribeMessage`` and the generated
/// OpenAI-compatible `Components.Schemas.ChatMessage` type. Kept
/// `package`-internal so embedders never have to know about the
/// transport type to use the public agent surface.
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
    self.init(
      role: role,
      content: chatMessage.content ?? "",
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
    let calls = toolCalls?.map { tc in
      Components.Schemas.AssistantToolCall(
        id: tc.id,
        _type: "function",
        function: .init(name: tc.name, arguments: tc.arguments)
      )
    }
    return Components.Schemas.ChatMessage(
      role: role,
      content: content,
      name: name,
      toolCalls: calls,
      toolCallId: toolCallId,
      reasoningContent: reasoning
    )
  }
}

extension Array where Element == ScribeMessage {
  package func toChatMessages() -> [Components.Schemas.ChatMessage] {
    map { $0.toChatMessage() }
  }
}

extension Array where Element == Components.Schemas.ChatMessage {
  package func toScribeMessages() -> [ScribeMessage] {
    map(ScribeMessage.init)
  }
}
