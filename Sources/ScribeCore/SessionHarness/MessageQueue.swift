import Foundation
import Synchronization

public enum QueueMode: Sendable, Equatable {
  case oneAtATime
  case all
}

public struct PendingMessageQueue: Sendable {
  private var messages: [ScribeMessage] = []
  public private(set) var mode: QueueMode

  public init(mode: QueueMode = .oneAtATime) {
    self.mode = mode
  }

  public var isEmpty: Bool { messages.isEmpty }
  public var count: Int { messages.count }
  public var previewTexts: [String] { messages.map(\.content) }

  public mutating func setMode(_ mode: QueueMode) {
    self.mode = mode
  }

  @discardableResult
  public mutating func enqueue(text: String) -> Bool {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return false }
    messages.append(ScribeMessage(role: .user, content: trimmed))
    return true
  }

  public mutating func enqueue(_ message: ScribeMessage) {
    guard message.role == .user else { return }
    messages.append(message)
  }

  @discardableResult
  public mutating func popFirst() -> ScribeMessage? {
    guard !messages.isEmpty else { return nil }
    return messages.removeFirst()
  }

  public mutating func clear() {
    messages = []
  }

  public mutating func drain(mode override: QueueMode? = nil) -> [ScribeMessage] {
    let mode = override ?? mode
    guard !messages.isEmpty else { return [] }
    switch mode {
    case .oneAtATime:
      return [messages.removeFirst()]
    case .all:
      let drained = messages
      messages = []
      return drained
    }
  }
}

/// The single FIFO queue of user messages waiting behind the active turn.
public final class SessionMessageQueue: Sendable {
  private let lock: Mutex<PendingMessageQueue>

  public var mode: QueueMode {
    lock.withLock { $0.mode }
  }

  public init(mode: QueueMode = .oneAtATime) {
    self.lock = Mutex(PendingMessageQueue(mode: mode))
  }

  public func setMode(_ mode: QueueMode) {
    lock.withLock { $0.setMode(mode) }
  }

  @discardableResult
  public func enqueue(text: String) -> Bool {
    lock.withLock { $0.enqueue(text: text) }
  }

  public func count() -> Int {
    lock.withLock { $0.count }
  }

  public func previewTexts() -> [String] {
    lock.withLock { $0.previewTexts }
  }

  @discardableResult
  public func popFirst() -> ScribeMessage? {
    lock.withLock { $0.popFirst() }
  }

  public func popForRecall() -> String? {
    popFirst()?.content
  }

  public func clear() {
    lock.withLock { $0.clear() }
  }

  func drain() -> [ScribeMessage] {
    lock.withLock { $0.drain() }
  }
}
