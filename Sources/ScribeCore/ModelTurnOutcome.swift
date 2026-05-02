import Foundation

/// Result of ``AgentHarness/runModelTurn(messages:logger:)`` when the HTTP stream completes.
public enum ModelTurnOutcome: Sendable, Equatable {
  /// Normal end: assistant produced a final reply (no pending tool calls).
  case completed
  /// The tool loop exhausted the configured round budget (see `scribe-config.json`).
  case hitToolRoundLimit
}
