import Foundation

extension Array where Element == ScribeMessage {

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
