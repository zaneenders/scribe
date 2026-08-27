import Foundation
import ScribeCore

@testable import ScribeCLI
@testable import ScribeKit

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

  mutating func handle(_ events: [AgentEvent], followingLive: Bool = true) {
    for event in events {
      handle(event, followingLive: followingLive)
    }
  }

  @discardableResult
  mutating func handleUserSubmitted(_ text: String) -> TranscriptController.Effects {
    TranscriptController.applyUserSubmitted(text, state: &state, theme: theme)
  }

  func batchRender(_ messages: [ScribeMessage]) -> [TLine] {
    renderMessagesToTranscript(messages, theme: theme, renderer: renderer)
  }
}
