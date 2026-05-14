import Foundation
import ScribeCore
import ScribeLLM

// MARK: - ChatDriver

/// Headless orchestrator that wires `TranscriptController` + `MarkdownRenderer`
/// together without Slate, `@MainActor`, or a terminal.
///
/// Reference "embedder for the headless side": copy this file into your own
/// server / CI tool to drive the public ``ScribeCore`` agent surface (via
/// ``ChatCoordinator``) without pulling the Slate-based TUI. The two
/// touchpoints to customise are:
///
/// - ``MarkdownRenderer`` — swap in a plain-text / HTML renderer for
///   non-terminal hosts.
/// - the `TranscriptEvent` sink — any sequence of events emitted by
///   ``ScribeAgent.prompt(_:options:log:)`` (or relayed by
///   ``ChatCoordinator``) feeds straight in via ``handle(_:followingLive:)``.
///
/// The driver holds no references to Slate, no `@MainActor`, no terminal
/// I/O — it is unit-testable as a pure state machine.
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

  /// Render the complete transcript from a list of agent messages (batch path).
  /// Useful for comparison against the streaming path in golden tests.
  func batchRender(_ messages: [ScribeMessage]) -> [TLine] {
    renderMessagesToTranscript(messages.toChatMessages(), theme: theme, renderer: renderer)
  }

  /// Wire-typed batch render — preserved for in-tree CLI code that still
  /// threads `Components.Schemas.ChatMessage` through its persistence
  /// layer. New code should prefer the ``ScribeMessage`` overload above.
  func batchRender(_ messages: [Components.Schemas.ChatMessage]) -> [TLine] {
    renderMessagesToTranscript(messages, theme: theme, renderer: renderer)
  }
}
