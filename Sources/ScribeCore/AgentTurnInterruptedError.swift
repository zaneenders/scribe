import Foundation

/// Thrown when an interactive host asks to stop the current model/tool round (for example Ctrl+C in fullscreen chat).
public struct AgentTurnInterruptedError: Error, Sendable {}
