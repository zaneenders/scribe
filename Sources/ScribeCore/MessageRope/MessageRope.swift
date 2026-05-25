import _RopeModule

public struct MessageRope: Sendable {
  public typealias _Rope = Rope<Message>

  private var _rope: _Rope

  public init() {
    self._rope = Rope()
  }

  public init(_ messages: [ScribeMessage]) {
    var elements: [Message] = []
    var chunk: [ScribeMessage] = []
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

  public var count: Int {
    _rope.count(in: MessageMetric())
  }

  public var isEmpty: Bool {
    _rope.isEmpty
  }

  public var first: ScribeMessage? {
    guard !isEmpty, let leaf = _rope.first else { return nil }
    return leaf.messages.first
  }

  public var last: ScribeMessage? {
    guard !isEmpty, let leaf = _rope.last else { return nil }
    return leaf.messages.last
  }

  public subscript(index: Int) -> ScribeMessage {
    precondition(index >= 0 && index < count, "MessageRope index out of bounds")
    return window(from: index, count: 1)[0]
  }

  public mutating func append(_ message: ScribeMessage) {
    _rope.append(Message(messages: [message]))
  }

  public mutating func append(contentsOf messages: [ScribeMessage]) {
    for m in messages { append(m) }
  }

  public func window(from start: Int, count requestedCount: Int) -> [ScribeMessage] {
    guard start >= 0, requestedCount > 0, !isEmpty else { return [] }
    let metric = MessageMetric()
    let total = _rope.count(in: metric)
    guard start < total else { return [] }
    let end = min(start + requestedCount, total)
    var result: [ScribeMessage] = []
    result.reserveCapacity(end - start)

    var idx = _rope.startIndex
    var offset = 0

    while idx < _rope.endIndex {
      let leaf = _rope[idx]
      let leafCount = leaf.messages.count
      if offset + leafCount > start { break }
      offset += leafCount
      _rope.formIndex(after: &idx)
    }

    if idx < _rope.endIndex {
      let leaf = _rope[idx]
      let localStart = start - offset
      let take = min(leaf.messages.count - localStart, end - start)
      result.append(contentsOf: leaf.messages[localStart..<localStart + take])
      _rope.formIndex(after: &idx)
    }

    while result.count < end - start, idx < _rope.endIndex {
      let leaf = _rope[idx]
      let take = min(leaf.messages.count, end - start - result.count)
      result.append(contentsOf: leaf.messages.prefix(take))
      _rope.formIndex(after: &idx)
    }

    return result
  }

  public func toArray() -> [ScribeMessage] {
    var out: [ScribeMessage] = []
    out.reserveCapacity(count)
    forEach { out.append($0) }
    return out
  }

  public mutating func truncate(to newCount: Int) {
    precondition(newCount >= 0, "truncate count must be >= 0")
    let current = count
    guard newCount < current else { return }
    if newCount == 0 {
      self._rope = Rope()
      return
    }

    let metric = MessageMetric()
    _rope.removeSubrange(newCount..<current, in: metric)
  }

  public mutating func splice(_ range: Range<Int>, with replacement: [ScribeMessage]) {
    let total = count
    precondition(range.lowerBound >= 0, "splice lowerBound < 0")
    precondition(range.upperBound <= total, "splice upperBound > count")
    precondition(range.lowerBound <= range.upperBound, "splice range inverted")

    var arr = toArray()
    arr.replaceSubrange(range, with: replacement)
    self = MessageRope(arr)
  }

  public func forEach(_ body: (ScribeMessage) throws -> Void) rethrows {
    for leaf in _rope {
      for msg in leaf.messages {
        try body(msg)
      }
    }
  }

  public func safeForkBoundaries() -> [Int] {
    var openToolCalls = Set<String>()
    var boundaries: [Int] = []
    var index = 0
    forEach { message in
      switch message.role {
      case .assistant:
        if let calls = message.toolCalls {
          for call in calls {
            openToolCalls.insert(call.id)
          }
        }
      case .tool:
        if let id = message.toolCallId { openToolCalls.remove(id) }
      case .system, .user:
        break
      }
      index += 1
      if openToolCalls.isEmpty {
        boundaries.append(index)
      }
    }
    return boundaries
  }
}
