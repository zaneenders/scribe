import Foundation
import ScribeCore


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
/// - the `AgentEvent` sink — any sequence of events emitted by
///   ``ScribeAgent.stream(_:options:)`` (or relayed by
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
    _ event: AgentEvent,
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
  mutating func handle(_ events: [AgentEvent], followingLive: Bool = true) {
    for event in events {
      handle(event, followingLive: followingLive)
    }
  }

  /// Record a user submission in the transcript (equivalent to the
  /// host emitting `HostEvent.userSubmitted`).
  @discardableResult
  mutating func handleUserSubmitted(_ text: String) -> TranscriptController.Effects {
    TranscriptController.applyUserSubmitted(text, state: &state, theme: theme)
  }

  /// Render the complete transcript from a list of agent messages (batch path).
  /// Useful for comparison against the streaming path in golden tests.
  func batchRender(_ messages: [ScribeMessage]) -> [TLine] {
    renderMessagesToTranscript(messages, theme: theme, renderer: renderer)
  }
}
