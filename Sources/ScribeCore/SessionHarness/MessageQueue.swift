import Foundation
import Synchronization

/// How queued messages are delivered when drained.
public enum QueueMode: Sendable, Equatable {
  /// Deliver one message, wait for the agent to finish, then deliver the next.
  ///
  /// Default for steering — lets the user interrupt or recall between
  /// auto-flushes (unlike the old TUI burst flush of every queued message).
  case oneAtATime
  /// Deliver every queued message in a single agent turn.
  case all
}

/// Which queue a pending user message belongs to.
public enum MessageQueueKind: Sendable, Equatable {
  /// Injected after the current assistant turn and tool batch finish.
  case steering
  /// Injected only when the agent would otherwise stop.
  case followUp
}

/// FIFO queue of user messages with a configurable drain strategy.
///
/// Uses ``ScribeMessage`` today; when transcript vs wire types split (see
/// architecture doc §2), this can adopt ``TranscriptMessage`` without changing
/// call sites on ``SessionHarness``.
public struct PendingMessageQueue: Sendable {
  private var messages: [ScribeMessage] = []
  public private(set) var mode: QueueMode

  public init(mode: QueueMode = .oneAtATime) {
    self.mode = mode
  }

  public var isEmpty: Bool { messages.isEmpty }

  public var count: Int { messages.count }

  /// Preview of queued user text (oldest first) for UI trays.
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

  /// Remove and return the oldest message, if any.
  @discardableResult
  public mutating func popFirst() -> ScribeMessage? {
    guard !messages.isEmpty else { return nil }
    return messages.removeFirst()
  }

  public mutating func clear() {
    messages = []
  }

  /// Remove messages according to ``mode`` (or an explicit override).
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

/// Thread-safe pair of steering and follow-up queues for ``SessionHarness``.
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
