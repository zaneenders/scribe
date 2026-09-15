import Foundation
import ScribeCore

func finalizedEvents(in events: [AgentEvent]) -> [AgentEvent] {
  events.filter {
    if case .output(.finalized) = $0 { return true }
    return false
  }
}

func emptyEvents(in events: [AgentEvent]) -> [AgentEvent] {
  events.filter {
    if case .output(.empty) = $0 { return true }
    return false
  }
}
