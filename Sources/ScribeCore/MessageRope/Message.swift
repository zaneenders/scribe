import _RopeModule

public struct Message: RopeElement, Sendable {
  public typealias Summary = MessageSummary
  public typealias Index = Int

  public var messages: [ScribeMessage]

  public var summary: MessageSummary { MessageSummary(count: messages.count) }

  public var isEmpty: Bool { messages.isEmpty }

  public var isUndersized: Bool {
    isEmpty
  }

  public func invariantCheck() {
    assert(
      messages.count <= MessageSummary.maxNodeSize,
      "Message leaf exceeds maxNodeSize")
  }

  public mutating func rebalance(nextNeighbor right: inout Message) -> Bool {

    if isUndersized, !right.isEmpty {
      let need = MessageSummary.maxNodeSize / 2 - messages.count
      let take = min(need, right.messages.count)
      if take > 0 {
        messages.append(contentsOf: right.messages.prefix(take))
        right.messages = Array(right.messages.dropFirst(take))
      }
    }

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

  public init(messages: [ScribeMessage]) {
    self.messages = messages
  }

  public init() {
    self.messages = []
  }
}

extension Message: Equatable {
  public static func == (lhs: Message, rhs: Message) -> Bool {
    lhs.messages == rhs.messages
  }
}
