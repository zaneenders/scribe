import ScribeLLM
import _RopeModule

// MARK: - MessageSummary

/// Count-based summary for chat messages.  Each message contributes 1.
public struct MessageSummary: RopeSummary {
  public var count: Int

  public static let maxNodeSize: Int = 32
  public static let zero: Self = MessageSummary(count: 0)

  public var isZero: Bool { count == 0 }

  public init(count: Int) { self.count = count }

  public mutating func add(_ other: Self) { count += other.count }
  public mutating func subtract(_ other: Self) { count -= other.count }
}

// MARK: - MessageMetric

/// Measures a `Message` in terms of raw message count.
public struct MessageMetric: RopeMetric {
  public typealias Element = Message

  public func size(of summary: MessageSummary) -> Int {
    summary.count
  }

  public func index(at offset: Int, in element: Message) -> Int {
    offset
  }
}

// MARK: - Message

/// A leaf buffer holding zero or more `ChatMessage` values.
///
/// Each leaf holds at most `MessageSummary.maxNodeSize` (32) messages.
public struct Message: RopeElement, Sendable {
  public typealias Summary = MessageSummary
  public typealias Index = Int

  public var messages: [Components.Schemas.ChatMessage]

  // MARK: - RopeElement

  public var summary: MessageSummary { MessageSummary(count: messages.count) }

  public var isEmpty: Bool { messages.isEmpty }

  public var isUndersized: Bool {
    isEmpty
  }

  public func invariantCheck() {
    assert(messages.count <= MessageSummary.maxNodeSize,
           "Message leaf exceeds maxNodeSize")
  }

  /// Move content from `right` into `self` (or vice versa) so neither is
  /// undersized.  Returns `true` if `right` became empty.
  public mutating func rebalance(nextNeighbor right: inout Message) -> Bool {
    // If we're undersized, pull from right.
    if isUndersized, !right.isEmpty {
      let need = MessageSummary.maxNodeSize / 2 - messages.count
      let take = min(need, right.messages.count)
      if take > 0 {
        messages.append(contentsOf: right.messages.prefix(take))
        right.messages = Array(right.messages.dropFirst(take))
      }
    }
    // If right is now undersized, push into it.
    if right.isUndersized, !messages.isEmpty {
      let give = min(messages.count - MessageSummary.maxNodeSize / 2, messages.count)
      if give > 0 {
        right.messages = Array(messages.suffix(give)) + right.messages
        messages = Array(messages.dropLast(give))
      }
    }
    return right.isEmpty
  }

  public mutating func rebalance(prevNeighbor left: inout Message) -> Bool {
    // Default implementation swaps and calls rebalance(nextNeighbor:).
    guard left.rebalance(nextNeighbor: &self) else { return false }
    swap(&self, &left)
    return true
  }

  public mutating func split(at index: Int) -> Message {
    precondition(index >= 0 && index <= messages.count, "split index out of bounds")
    let tail = Array(messages[index...])
    messages = Array(messages[..<index])
    return Message(messages: tail)
  }

  // MARK: - Init

  public init(messages: [Components.Schemas.ChatMessage]) {
    self.messages = messages
  }

  public init() {
    self.messages = []
  }
}

// MARK: - Equatable

extension Message: Equatable {
  public static func == (lhs: Message, rhs: Message) -> Bool {
    guard lhs.messages.count == rhs.messages.count else { return false }
    for (a, b) in zip(lhs.messages, rhs.messages) {
      if a.role != b.role { return false }
      if a.content != b.content { return false }
    }
    return true
  }
}

// MARK: - MessageRope

/// A `Rope<Message>` specialised for chat history.
///
/// Wraps swift-collections `Rope<Message>` and exposes a chat-friendly API:
/// append single messages, extract viewport windows, truncate, iterate.
public struct MessageRope: Sendable {
  public typealias _Rope = Rope<Message>

  private var _rope: _Rope

  // MARK: - Init

  public init() {
    self._rope = Rope()
  }

  /// Bulk-load from an array of messages, chunked into leaves of up to 32.
  public init(_ messages: [Components.Schemas.ChatMessage]) {
    var elements: [Message] = []
    var chunk: [Components.Schemas.ChatMessage] = []
    chunk.reserveCapacity(MessageSummary.maxNodeSize)
    for msg in messages {
      chunk.append(msg)
      if chunk.count >= MessageSummary.maxNodeSize {
        elements.append(Message(messages: chunk))
        chunk = []
      }
    }
    if !chunk.isEmpty {
      elements.append(Message(messages: chunk))
    }
    self._rope = Rope()
    for el in elements {
      _rope.append(el)
    }
  }

  internal init(_rope: _Rope) {
    self._rope = _rope
  }

  // MARK: - Properties

  public var count: Int {
    _rope.count(in: MessageMetric())
  }

  public var isEmpty: Bool {
    _rope.isEmpty
  }

  public var first: Components.Schemas.ChatMessage? {
    guard !isEmpty, let leaf = _rope.first else { return nil }
    return leaf.messages.first
  }

  public var last: Components.Schemas.ChatMessage? {
    guard !isEmpty, let leaf = _rope.last else { return nil }
    return leaf.messages.last
  }

  // MARK: - Append

  public mutating func append(_ message: Components.Schemas.ChatMessage) {
    _rope.append(Message(messages: [message]))
  }

  // MARK: - Window

  /// Return `requestedCount` messages starting at `start` (0-indexed).
  public func window(from start: Int, count requestedCount: Int) -> [Components.Schemas.ChatMessage] {
    guard start >= 0, requestedCount > 0, !isEmpty else { return [] }
    let metric = MessageMetric()
    let total = _rope.count(in: metric)
    guard start < total else { return [] }
    let end = min(start + requestedCount, total)
    var result: [Components.Schemas.ChatMessage] = []
    result.reserveCapacity(end - start)

    // Find the start index and walk forward collecting messages.
    var idx = _rope.startIndex
    var offset = 0
    // Advance idx past leaves that end before `start`.
    while idx < _rope.endIndex {
      let leaf = _rope[idx]
      let leafCount = leaf.messages.count
      if offset + leafCount > start { break }
      offset += leafCount
      _rope.formIndex(after: &idx)
    }

    // Collect from the first overlapping leaf.
    if idx < _rope.endIndex {
      let leaf = _rope[idx]
      let localStart = start - offset
      let take = min(leaf.messages.count - localStart, end - start)
      result.append(contentsOf: leaf.messages[localStart ..< localStart + take])
      _rope.formIndex(after: &idx)
    }

    // Collect remaining full leaves.
    while result.count < end - start, idx < _rope.endIndex {
      let leaf = _rope[idx]
      let take = min(leaf.messages.count, end - start - result.count)
      result.append(contentsOf: leaf.messages.prefix(take))
      _rope.formIndex(after: &idx)
    }

    return result
  }

  // MARK: - Truncate

  public mutating func truncate(to newCount: Int) {
    precondition(newCount >= 0, "truncate count must be >= 0")
    let current = count
    guard newCount < current else { return }
    if newCount == 0 {
      self._rope = Rope()
      return
    }

    let metric = MessageMetric()
    _rope.removeSubrange(newCount ..< current, in: metric)
  }

  // MARK: - forEach

  public func forEach(_ body: (Components.Schemas.ChatMessage) throws -> Void) rethrows {
    for leaf in _rope {
      for msg in leaf.messages {
        try body(msg)
      }
    }
  }
}
