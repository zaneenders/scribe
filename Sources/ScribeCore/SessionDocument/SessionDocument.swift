import Foundation
import Logging
import ScribeLLM
import SystemPackage

public struct SessionDocument: ~Copyable {

  public private(set) var sessionId: UUID
  public private(set) var directory: FilePath

  private var messages: [ScribeMessage]
  private let logger: Logger

  public init(
    sessionId: UUID,
    directory: FilePath,
    logger: Logger
  ) {
    self.sessionId = sessionId
    self.directory = directory
    self.messages = []
    self.logger = logger
  }

  private init(
    sessionId: UUID,
    directory: FilePath,
    messages: [ScribeMessage],
    logger: Logger
  ) {
    self.sessionId = sessionId
    self.directory = directory
    self.messages = messages
    self.logger = logger
  }

  public var count: Int { messages.count }

  public var isEmpty: Bool { messages.isEmpty }

  public subscript(index: Int) -> ScribeMessage {
    messages[index]
  }

  public borrowing func safeForkBoundaries() -> [Int] {
    messages.safeForkBoundaries()
  }

  package borrowing func agentHistory() -> [ScribeMessage] {
    messages
  }

  package borrowing func chatMessages() -> [Components.Schemas.ChatMessage] {
    messages.toWireMessages()
  }

  @discardableResult
  public mutating func append(_ messages: [ScribeMessage]) -> Range<Int> {
    guard !messages.isEmpty else {
      return self.messages.count..<self.messages.count
    }
    let startIndex = self.messages.count
    self.messages.append(contentsOf: messages)
    let range = startIndex..<self.messages.count
    logger.trace(
      "session.doc.append",
      metadata: [
        "added": "\(messages.count)",
        "total": "\(self.messages.count)",
      ])
    return range
  }

  public borrowing func successor(
    splicing range: Range<Int>,
    inserting replacement: [ScribeMessage] = [],
    newSessionId: UUID,
    newDirectory: FilePath
  ) -> SessionDocument {
    precondition(range.lowerBound >= 0 && range.upperBound <= count, "successor splice out of bounds")
    var newMessages = messages
    newMessages.replaceSubrange(range, with: replacement)
    logger.notice(
      "session.doc.successor",
      metadata: [
        "splice": "\(range.lowerBound)..<\(range.upperBound)",
        "replacement_messages": "\(replacement.count)",
        "child": "\(newSessionId.uuidString)",
        "new_count": "\(newMessages.count)",
      ])
    return SessionDocument(
      sessionId: newSessionId,
      directory: newDirectory,
      messages: newMessages,
      logger: logger
    )
  }
}
