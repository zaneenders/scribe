import Foundation
import ScribeCore

/// One presentation-neutral transcript row. Identity is a stable string:
/// deterministic for replayed persisted messages, provisional (but stable
/// while text streams) for live turns. Carries no layout, scroll, focus, or
/// selection state — those belong to the rendering layer.
public struct ScribeTranscriptItem: Codable, Sendable, Equatable, Identifiable {

  /// Stable transcript identity.
  ///
  /// Replay IDs are derived from the session ID plus the source message
  /// position and segment (user, reasoning, answer, tool call), so replaying
  /// the same persisted messages always yields the same IDs. Streamed items
  /// use provisional `stream:` IDs that stay unchanged while text is appended,
  /// and are reconciled into replay IDs when a terminal event applies the
  /// authoritative persisted messages.
  public struct ID: Hashable, Sendable, Codable, RawRepresentable, CustomStringConvertible {

    public var rawValue: String

    public init(rawValue: String) {
      self.rawValue = rawValue
    }

    public var description: String { rawValue }

    /// Deterministic identity for a replayed persisted message segment.
    public static func replay(
      sessionID: UUID, messageIndex: Int, segment: String
    ) -> ID {
      ID(rawValue: "replay:\(sessionID.uuidString):\(messageIndex):\(segment)")
    }

    /// Deterministic identity for a tool call within a replayed assistant message.
    public static func replayToolCall(
      sessionID: UUID, messageIndex: Int, callID: String
    ) -> ID {
      ID(rawValue: "replay:\(sessionID.uuidString):\(messageIndex):call:\(callID)")
    }

    /// Deterministic identity for a replayed standalone tool-result message.
    public static func replayToolResult(
      sessionID: UUID, messageIndex: Int
    ) -> ID {
      ID(rawValue: "replay:\(sessionID.uuidString):\(messageIndex):tool")
    }

    /// Provisional identity for a streamed segment in the given turn.
    public static func stream(sessionID: UUID, turn: Int, segment: String) -> ID {
      ID(rawValue: "stream:\(sessionID.uuidString):\(turn):\(segment)")
    }

    /// Provisional identity for a streamed tool invocation occurrence.
    public static func streamTool(
      sessionID: UUID, turn: Int, name: String, occurrence: Int
    ) -> ID {
      ID(rawValue: "stream:\(sessionID.uuidString):\(turn):tool:\(name):\(occurrence)")
    }

    /// Identity for presentation-only notices that are never replayed.
    public static func notice(sessionID: UUID, ordinal: Int) -> ID {
      ID(rawValue: "notice:\(sessionID.uuidString):\(ordinal)")
    }
  }

  public enum Kind: String, Codable, Sendable, Equatable {

    case user

    case answer

    case reasoning

    case tool

    case notice

    case warning

    case error
  }

  public var id: ID

  public var kind: Kind

  public var title: String

  public var body: String

  public var isRunning: Bool

  /// Position of the persisted source message this item was replayed from.
  public var sourceMessageIndex: Int?

  public init(
    id: ID,
    kind: Kind,
    title: String,
    body: String,
    isRunning: Bool = false,
    sourceMessageIndex: Int? = nil
  ) {
    self.id = id
    self.kind = kind
    self.title = title
    self.body = body
    self.isRunning = isRunning
    self.sourceMessageIndex = sourceMessageIndex
  }
}

/// Presentation titles shared by replay and streaming reduction, so both
/// paths describe sections identically.
extension ScribeStreamSection {

  var transcriptTitle: String {
    switch self {
    case .reasoning: return "Reasoning"
    case .answer: return "Scribe"
    }
  }
}

/// Single owner of transcript replay and streamed event reduction.
///
/// `replay` is deterministic: the same persisted messages always produce the
/// same item IDs and order. `apply` reduces one live `ScribeSessionEvent`,
/// keeping provisional IDs stable while streamed text is appended. Terminal
/// events reconcile the turn by replaying the authoritative messages, which
/// replaces provisional IDs with deterministic replay IDs.
public struct ScribeTranscriptState: Sendable, Equatable {

  public private(set) var sessionID: UUID

  public private(set) var items: [ScribeTranscriptItem]

  /// Formatted usage line for the latest turn (for example
  /// `"42 tokens | 10.5 tok/s"`); empty before the first usage event.
  public private(set) var usageText: String

  private var turnCounter: Int

  private var noticeCounter: Int

  /// Number of authoritative messages already reflected in `items`. Terminal
  /// events reconcile only the suffix appended by the completed turn.
  private var reconciledMessageCount: Int

  public init(sessionID: UUID, messages: [ScribeMessage] = []) {
    self.sessionID = sessionID
    self.items = Self.replay(sessionID: sessionID, messages: messages)
    self.usageText = ""
    self.turnCounter = 0
    self.noticeCounter = 0
    self.reconciledMessageCount = messages.count
  }

  /// Rebuilds the transcript from authoritative persisted messages. Used when
  /// opening a session, after identity changes, and whenever the whole
  /// history must be recomputed. Presentation notices recorded so far are
  /// replaced with the replayed history.
  public mutating func reconcile(messages: [ScribeMessage]) {
    items = Self.replay(sessionID: sessionID, messages: messages)
    reconciledMessageCount = messages.count
  }

  /// Appends a presentation-only notice, warning, or error item (queue and
  /// command feedback). These items are not derived from persisted messages.
  public mutating func appendPresentationItem(
    kind: ScribeTranscriptItem.Kind, title: String, body: String
  ) {
    let id = ScribeTranscriptItem.ID.notice(sessionID: sessionID, ordinal: noticeCounter)
    noticeCounter += 1
    items.append(
      ScribeTranscriptItem(id: id, kind: kind, title: title, body: body))
  }

  /// Removes every streamed item belonging to the current (in-flight) turn.
  /// Used when a stream ends without a terminal event so the transcript can
  /// fall back to the last reconciled state.
  public mutating func discardActiveTurn() {
    let prefix = "stream:\(sessionID.uuidString):\(turnCounter):"
    items.removeAll { $0.id.rawValue.hasPrefix(prefix) }
  }

  // MARK: - Replay

  /// Deterministically maps persisted messages to transcript items.
  public static func replay(sessionID: UUID, messages: [ScribeMessage]) -> [ScribeTranscriptItem] {
    var result: [ScribeTranscriptItem] = []
    for (messageIndex, message) in messages.enumerated() {
      replayMessage(message, sessionID: sessionID, messageIndex: messageIndex, into: &result)
    }
    return result
  }

  /// Maps one persisted message at a known position into `result`.
  static func replayMessage(
    _ message: ScribeMessage,
    sessionID: UUID,
    messageIndex: Int,
    into result: inout [ScribeTranscriptItem]
  ) {
    switch message.role {
    case .system:
      return
    case .user:
      result.append(
        ScribeTranscriptItem(
          id: .replay(sessionID: sessionID, messageIndex: messageIndex, segment: "user"),
          kind: .user,
          title: "You",
          body: message.content,
          sourceMessageIndex: messageIndex))
    case .assistant:
      if let reasoning = message.reasoning, !reasoning.isEmpty {
        result.append(
          ScribeTranscriptItem(
            id: .replay(sessionID: sessionID, messageIndex: messageIndex, segment: "reasoning"),
            kind: .reasoning,
            title: "Reasoning",
            body: reasoning,
            sourceMessageIndex: messageIndex))
      }
      if !message.content.isEmpty {
        result.append(
          ScribeTranscriptItem(
            id: .replay(sessionID: sessionID, messageIndex: messageIndex, segment: "answer"),
            kind: .answer,
            title: "Scribe",
            body: message.content,
            sourceMessageIndex: messageIndex))
      }
      for call in message.toolCalls ?? [] {
        result.append(
          ScribeTranscriptItem(
            id: .replayToolCall(
              sessionID: sessionID, messageIndex: messageIndex, callID: call.id),
            kind: .tool,
            title: call.name,
            body: argumentSummaryText(name: call.name, arguments: call.arguments) ?? "",
            isRunning: true,
            sourceMessageIndex: messageIndex))
      }
    case .tool:
      let matchingIndex = toolResultAttachmentIndex(
        in: result, toolCallID: message.toolCallId)
      if let matchingIndex {
        let lines = ToolInvocationFormatting.outputLines(
          name: result[matchingIndex].title, jsonOutput: message.content)
        if !result[matchingIndex].body.isEmpty, !lines.isEmpty {
          result[matchingIndex].body += "\n"
        }
        result[matchingIndex].body += lines.joined(separator: "\n")
        result[matchingIndex].isRunning = false
      } else {
        let name = message.name ?? "Tool"
        result.append(
          ScribeTranscriptItem(
            id: .replayToolResult(sessionID: sessionID, messageIndex: messageIndex),
            kind: .tool,
            title: name,
            body: ToolInvocationFormatting.outputLines(
              name: name, jsonOutput: message.content
            ).joined(separator: "\n"),
            sourceMessageIndex: messageIndex))
      }
    }
  }

  /// Finds the running tool item a tool-result message attaches to: the call
  /// whose ID matches the result's `toolCallId`, or the last running tool item
  /// when the reference is missing or unknown.
  private static func toolResultAttachmentIndex(
    in items: [ScribeTranscriptItem], toolCallID: String?
  ) -> Int? {
    if let toolCallID,
      let index = items.lastIndex(where: {
        $0.kind == .tool && $0.isRunning && $0.id.rawValue.hasSuffix("call:\(toolCallID)")
      })
    {
      return index
    }
    return items.lastIndex(where: { $0.kind == .tool && $0.isRunning })
  }

  /// One-line argument summary for a tool invocation, used by replay and
  /// streamed tool items alike.
  public static func argumentSummaryText(name: String, arguments: String) -> String? {
    let trimmed = arguments.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    return ToolInvocationFormatting.argumentSummary(name: name, argumentsJSON: trimmed) ?? trimmed
  }

  // MARK: - Live event reduction

  /// Reduces one live stream event into the transcript.
  public mutating func apply(_ event: ScribeSessionEvent) {
    switch event {
    case .userPromptAccepted(let text):
      beginTurn()
      items.append(
        ScribeTranscriptItem(
          id: .stream(sessionID: sessionID, turn: turnCounter, segment: "user"),
          kind: .user,
          title: "You",
          body: text))
    case .sectionStarted(let section):
      ensureStreamItem(section)
    case .sectionTextAppended(let section, let text):
      appendStreamText(text, to: section)
    case .toolRoundStarted:
      break
    case .toolInvocationStarted(let name, let arguments):
      upsertStreamTool(name: name, arguments: arguments, output: "", isRunning: true)
    case .toolInvocationCompleted(let name, let output):
      upsertStreamTool(name: name, arguments: "", output: output, isRunning: false)
    case .warning(let message):
      items.append(
        ScribeTranscriptItem(
          id: .notice(sessionID: sessionID, ordinal: noticeCounter),
          kind: .warning, title: "Warning", body: message))
      noticeCounter += 1
    case .error(let message):
      items.append(
        ScribeTranscriptItem(
          id: .notice(sessionID: sessionID, ordinal: noticeCounter),
          kind: .error, title: "Error", body: message))
      noticeCounter += 1
    case .retrying(let attempt, let maxAttempts, let delaySeconds, let reason):
      items.append(
        ScribeTranscriptItem(
          id: .notice(sessionID: sessionID, ordinal: noticeCounter),
          kind: .warning,
          title: "Retrying",
          body:
            "\(reason) (attempt \(attempt)/\(maxAttempts), delay: \(String(format: "%.1f", delaySeconds))s)"
        ))
      noticeCounter += 1
    case .recovered(let reason):
      items.append(
        ScribeTranscriptItem(
          id: .notice(sessionID: sessionID, ordinal: noticeCounter),
          kind: .warning, title: "Recovered", body: reason))
      noticeCounter += 1
    case .usage(let usage):
      var parts: [String] = []
      if let total = usage.totalTokens { parts.append("\(total) tokens") }
      if let rate = usage.tokensPerSecond { parts.append(String(format: "%.1f tok/s", rate)) }
      usageText = parts.joined(separator: " | ")
    case .emptyOutput:
      items.append(
        ScribeTranscriptItem(
          id: .notice(sessionID: sessionID, ordinal: noticeCounter),
          kind: .notice, title: "Scribe", body: "Empty response."))
      noticeCounter += 1
    case .interrupted:
      break
    case .identityChanged(_, let newSessionID):
      sessionID = newSessionID
    case .turnCompleted(let outcome, let messages):
      reconcileTurnSuffix(messages: messages)
      if case .interrupted = outcome {
        items.append(
          ScribeTranscriptItem(
            id: .notice(sessionID: sessionID, ordinal: noticeCounter),
            kind: .notice, title: "Stopped", body: "Response interrupted."))
        noticeCounter += 1
      }
    case .turnFailed(let message):
      items.append(
        ScribeTranscriptItem(
          id: .notice(sessionID: sessionID, ordinal: noticeCounter),
          kind: .error, title: "Error", body: message))
      noticeCounter += 1
    }
  }

  /// Reconciles the just-finished turn: provisional stream items are replaced
  /// by deterministic replay items for the messages the turn persisted.
  /// Earlier turns, their notices, and mid-turn notices are preserved.
  private mutating func reconcileTurnSuffix(messages: [ScribeMessage]) {
    guard messages.count >= reconciledMessageCount else {
      // History shrank or changed beneath us (fork/TLDR): full reset.
      reconcile(messages: messages)
      return
    }
    let streamPrefix = "stream:\(sessionID.uuidString):\(turnCounter):"
    items.removeAll { $0.id.rawValue.hasPrefix(streamPrefix) }
    for offset in reconciledMessageCount..<messages.count {
      Self.replayMessage(messages[offset], sessionID: sessionID, messageIndex: offset, into: &items)
    }
    reconciledMessageCount = messages.count
  }

  private mutating func beginTurn() {
    turnCounter += 1
  }

  private mutating func ensureStreamItem(_ section: ScribeStreamSection) {
    let kind: ScribeTranscriptItem.Kind = section == .reasoning ? .reasoning : .answer
    if items.last?.kind != kind {
      items.append(
        ScribeTranscriptItem(
          id: .stream(sessionID: sessionID, turn: turnCounter, segment: section.rawValue),
          kind: kind,
          title: section.transcriptTitle,
          body: "",
          isRunning: true))
    }
  }

  private mutating func appendStreamText(_ text: String, to section: ScribeStreamSection) {
    ensureStreamItem(section)
    items[items.count - 1].body += text
  }

  private mutating func upsertStreamTool(
    name: String, arguments: String, output: String, isRunning: Bool
  ) {
    if let index = items.lastIndex(where: {
      $0.kind == .tool && $0.title == name && $0.isRunning
    }) {
      if !output.isEmpty {
        let lines = ToolInvocationFormatting.outputLines(name: name, jsonOutput: output)
        if !items[index].body.isEmpty, !lines.isEmpty {
          items[index].body += "\n"
        }
        items[index].body += lines.joined(separator: "\n")
      }
      items[index].isRunning = isRunning
    } else {
      var sections: [String] = []
      if let summary = Self.argumentSummaryText(name: name, arguments: arguments) {
        sections.append(summary)
      }
      if !output.isEmpty {
        sections.append(
          ToolInvocationFormatting.outputLines(name: name, jsonOutput: output)
            .joined(separator: "\n"))
      }
      items.append(
        ScribeTranscriptItem(
          id: .streamTool(
            sessionID: sessionID, turn: turnCounter, name: name,
            occurrence: streamToolOccurrence(name: name)),
          kind: .tool,
          title: name,
          body: sections.joined(separator: "\n"),
          isRunning: isRunning))
    }
  }

  private func streamToolOccurrence(name: String) -> Int {
    let prefix = "stream:\(sessionID.uuidString):\(turnCounter):tool:\(name):"
    return items.filter { $0.id.rawValue.hasPrefix(prefix) }.count + 1
  }
}
