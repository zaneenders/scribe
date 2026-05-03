import Foundation
import Logging
import ScribeCore
import ScribeLLM
import SlateCore

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

internal enum ChatTerminalError: Error, LocalizedError {
  /// Stdin is not a TTY (pipes, redirection, CI, etc.).
  case notATerminal
  /// Slate declined or could not use the alternate-screen UI.
  case slateNotInteractive

  var errorDescription: String? {
    switch self {
    case .notATerminal:
      return "`scribe chat` requires an interactive terminal (stdin must be a TTY)."
    case .slateNotInteractive:
      return "`scribe chat` requires a fully interactive terminal; the fullscreen UI could not attach."
    }
  }
}

enum SlateChat {
  /// Runs the chat session using the Slate alternate-screen UI; fails if stdin is not a TTY or Slate cannot attach.
  ///
  /// When ``resumeArchive`` is `nil`, ``sessionPersistenceURL`` must end with `{uuid}.json` (see ``ChatSessionStore/fileURL(sessionId:configuration:)``).
  ///
  /// - Parameters:
  ///   - resumeArchive: If set, restores model context and redraws approximate transcript (`sessionPersistenceURL` should point at that archive).
  ///   - sessionId: UUID identifying this Scribe invocation (matches the `{uuid}.json` archive
  ///     stem and the `scribe-{uuid}.log` file the `log` parameter writes to).
  ///   - log: Per-session logger created in `Chat.run` via ``AgentConfig/makeSessionLogger(sessionId:)``.
  ///     All chat events for this invocation funnel into this single `Logger`; we no longer emit
  ///     to a separate diagnostics file.
  static func runFullscreen(
    configuration: AgentConfig,
    client: Client,
    systemPrompt: String,
    resumeArchive: ChatSessionArchive? = nil,
    sessionPersistenceURL: URL,
    sessionId: UUID,
    log: Logger
  ) async throws {
    guard isatty(STDIN_FILENO) != 0 else {
      log.error("event=chat.session.fail reason=stdin-not-tty")
      throw ChatTerminalError.notATerminal
    }
    log.debug(
      """
      event=chat.fullscreen.attach \
      session_file=\(sessionPersistenceURL.lastPathComponent)
      """
    )
    try await Task { @MainActor () throws -> Void in
      let sessionCreatedAt = resumeArchive?.createdAt ?? Date()
      let host = SlateChatHost(
        configuration: configuration,
        client: client,
        systemPrompt: systemPrompt,
        resumeArchive: resumeArchive,
        sessionPersistenceURL: sessionPersistenceURL,
        sessionId: sessionId,
        sessionCreatedAt: sessionCreatedAt,
        log: log
      )
      do {
        try await host.run()
      } catch Slate.InstallationError.notInteractiveTerminal {
        log.error(
          "event=chat.fullscreen.fail reason=slate-not-interactive"
        )
        throw ChatTerminalError.slateNotInteractive
      }
    }.value
  }
}
