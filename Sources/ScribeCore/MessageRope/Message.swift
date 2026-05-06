import ScribeLLM
import _RopeModule

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
    assert(
      messages.count <= MessageSummary.maxNodeSize,
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
