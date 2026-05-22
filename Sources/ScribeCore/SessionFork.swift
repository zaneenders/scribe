import Foundation

extension Array where Element == ScribeMessage {

  /// Indices `i` at which the prefix `messages[0..i)` forms a self-contained
  /// conversation — every assistant `tool_calls` has its matching `tool`
  /// results already present.
  ///
  /// Cutting the log inside a tool round would leave an assistant `tool_calls`
  /// message without its matching `tool` results, which providers reject on
  /// the next request. Forks and summaries must land on one of these.
  ///
  /// Boundaries are returned in ascending order. `0` is never returned (a
  /// cut that keeps nothing is not useful); `count` is returned when the log
  /// itself is in a closed state. Callers may apply further filters
  /// (e.g. require the system message be present, hide the trailing
  /// `count` cut from a "fork" picker).
  public func safeForkBoundaries() -> [Int] {
    var openToolCalls = Set<String>()
    var boundaries: [Int] = []
    for (index, message) in self.enumerated() {
      switch message.role {
      case .assistant:
        if let calls = message.toolCalls {
          for call in calls { openToolCalls.insert(call.id) }
        }
      case .tool:
        if let id = message.toolCallId { openToolCalls.remove(id) }
      case .system, .user:
        break
      }
      if openToolCalls.isEmpty {
        boundaries.append(index + 1)
      }
    }
    return boundaries
  }
}
