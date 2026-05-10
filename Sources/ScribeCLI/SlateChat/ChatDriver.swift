import Foundation
import ScribeCore
import ScribeLLM

// MARK: - ChatDriver

/// Headless orchestrator that wires `TranscriptController` + `MarkdownRenderer`
/// together without Slate, `@MainActor`, or a terminal.
///
/// This enables integration and golden tests to run without a TUI.
struct ChatDriver {
  var state: TranscriptState
  let renderer: MarkdownRenderer
  let theme: CLITheme
  let contextWindow: Int?

  init(
    state: TranscriptState = TranscriptState(),
    renderer: MarkdownRenderer = SwiftMarkdownRenderer(),
    theme: CLITheme = .default,
    contextWindow: Int? = nil
  ) {
    self.state = state
    self.renderer = renderer
    self.theme = theme
    self.contextWindow = contextWindow
  }

  /// Feed a transcript event into the pipeline and return the resulting effects.
  @discardableResult
  mutating func handle(
    _ event: TranscriptEvent,
    followingLive: Bool = true
  ) -> TranscriptController.Effects {
    TranscriptController.apply(
      event,
      to: &state,
      theme: theme,
      renderer: renderer,
      followingLive: followingLive,
      contextWindow: contextWindow
    )
  }

  /// Feed a sequence of events (simulating a full turn).
  mutating func handle(_ events: [TranscriptEvent], followingLive: Bool = true) {
    for event in events {
      handle(event, followingLive: followingLive)
    }
  }

  /// Render the complete transcript from a list of chat messages (batch path).
  /// Useful for comparison against the streaming path in golden tests.
  func batchRender(_ messages: [Components.Schemas.ChatMessage]) -> [TLine] {
    renderMessagesToTranscript(messages, theme: theme, renderer: renderer)
  }
}
