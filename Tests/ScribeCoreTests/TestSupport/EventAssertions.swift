import Foundation
import ScribeCore

// MARK: - Event filtering helpers

/// Returns only the `.output(.finalized)` events from the list.
func finalizedEvents(in events: [AgentEvent]) -> [AgentEvent] {
    events.filter {
        if case .output(.finalized) = $0 { return true }
        return false
    }
}

/// Returns only the `.output(.empty)` events from the list.
func emptyEvents(in events: [AgentEvent]) -> [AgentEvent] {
    events.filter {
        if case .output(.empty) = $0 { return true }
        return false
    }
}
