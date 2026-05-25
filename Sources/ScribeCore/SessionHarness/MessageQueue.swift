import Foundation
import Synchronization

public enum QueueMode: Sendable, Equatable {
  case oneAtATime
  case all
}

public enum MessageQueueKind: Sendable, Equatable {
  case steering
  case followUp
}

public struct PendingMessageQueue: Sendable {
  private var messages: [ScribeMessage] = []
  public private(set) var mode: QueueMode

  public init(mode: QueueMode = .oneAtATime) {
    self.mode = mode
  }

  public var isEmpty: Bool { messages.isEmpty }

  public var count: Int { messages.count }

  public var previewTexts: [String] {
    messages.map(\.content)
  }

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

final class SessionMessageQueues: Sendable {
  private let lock = Mutex(State())

  private struct State {
    var steering = PendingMessageQueue()
    var followUp = PendingMessageQueue()
  }

  var steeringMode: QueueMode {
    lock.withLock { $0.steering.mode }
  }

  var followUpMode: QueueMode {
    lock.withLock { $0.followUp.mode }
  }

  func setSteeringMode(_ mode: QueueMode) {
    lock.withLock { $0.steering.setMode(mode) }
  }

  func setFollowUpMode(_ mode: QueueMode) {
    lock.withLock { $0.followUp.setMode(mode) }
  }

  func enqueueSteering(text: String) -> Bool {
    lock.withLock { $0.steering.enqueue(text: text) }
  }

  func enqueueFollowUp(text: String) -> Bool {
    lock.withLock { $0.followUp.enqueue(text: text) }
  }

  func steeringCount() -> Int {
    lock.withLock { $0.steering.count }
  }

  func followUpCount() -> Int {
    lock.withLock { $0.followUp.count }
  }

  func steeringPreviewTexts() -> [String] {
    lock.withLock { $0.steering.previewTexts }
  }

  func followUpPreviewTexts() -> [String] {
    lock.withLock { $0.followUp.previewTexts }
  }

  @discardableResult
  func popSteeringFirst() -> ScribeMessage? {
    lock.withLock { $0.steering.popFirst() }
  }

  func clearSteering() {
    lock.withLock { $0.steering.clear() }
  }

  func clearFollowUp() {
    lock.withLock { $0.followUp.clear() }
  }

  func clearAll() {
    lock.withLock {
      $0.steering.clear()
      $0.followUp.clear()
    }
  }

  func drainSteering() -> [ScribeMessage] {
    lock.withLock { $0.steering.drain() }
  }

  func drainFollowUp() -> [ScribeMessage] {
    lock.withLock { $0.followUp.drain() }
  }
}
