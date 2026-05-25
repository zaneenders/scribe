import Foundation
import Logging
import ScribeLLM
import SystemPackage

public struct SessionDocument: ~Copyable {

  public private(set) var sessionId: UUID
  public private(set) var directory: FilePath

  private var rope: MessageRope
  private let logger: Logger

  public init(
    sessionId: UUID,
    directory: FilePath,
    logger: Logger
  ) {
    self.sessionId = sessionId
    self.directory = directory
    self.rope = MessageRope()
    self.logger = logger
  }

  private init(
    sessionId: UUID,
    directory: FilePath,
    rope: MessageRope,
    logger: Logger
  ) {
    self.sessionId = sessionId
    self.directory = directory
    self.rope = rope
    self.logger = logger
  }

  public var count: Int { rope.count }

  public var isEmpty: Bool { rope.isEmpty }

  public subscript(index: Int) -> ScribeMessage {
    rope[index]
  }

  public borrowing func safeForkBoundaries() -> [Int] {
    rope.safeForkBoundaries()
  }

  package borrowing func agentHistory() -> [ScribeMessage] {
    rope.toArray()
  }

  package borrowing func chatMessages() -> [Components.Schemas.ChatMessage] {
    rope.toArray().toWireMessages()
  }

  @discardableResult
  public mutating func append(_ messages: [ScribeMessage]) -> Range<Int> {
    guard !messages.isEmpty else {
      return rope.count..<rope.count
    }
    let startIndex = rope.count
    rope.append(contentsOf: messages)
    let range = startIndex..<rope.count
    logger.trace(
      "session.doc.append",
      metadata: [
        "added": "\(messages.count)",
        "total": "\(rope.count)",
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
    var newRope = rope
    newRope.splice(range, with: replacement)
    logger.notice(
      "session.doc.successor",
      metadata: [
        "splice": "\(range.lowerBound)..<\(range.upperBound)",
        "replacement_messages": "\(replacement.count)",
        "child": "\(newSessionId.uuidString)",
        "new_count": "\(newRope.count)",
      ])
    return SessionDocument(
      sessionId: newSessionId,
      directory: newDirectory,
      rope: newRope,
      logger: logger
    )
  }
}
