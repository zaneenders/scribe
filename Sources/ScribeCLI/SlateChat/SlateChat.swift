import Foundation
import Logging
import ScribeCore
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
  /// - Parameters:
  ///   - resumeMessages: Prior transcript restored from `sessions/{sessionId}/messages.jsonl`.
  ///   - sessionPersistenceURL: Directory `sessions/{sessionId}/` for metadata and JSONL.
  ///   - sessionId: UUID shared with `sessions/{sessionId}/scribe.log`.
  ///   - logger: Session logger from ``LoadedConfig/makeSessionLogger(sessionId:)`` (also passed
  ///     into ``ScribeAgent`` inside ``ChatCoordinator``).
  ///
  /// ## Logs
  ///
  /// One append-only file per session id under `{dataHome}/sessions/{sessionId}/scribe.log`. Lines look like:
  /// `<iso8601-ms> [<level>] <domain.action> key=value …` — message is the event name;
  /// fields live in swift-log metadata (see `Sources/ScribeCLI/Logging/`).
  ///
  /// Chat UI events are documented on ``SlateChatHost`` and ``ChatCoordinator``; agent/tool
  /// events use the `agent.*` prefix from ScribeCore.
  static func runFullscreen(
    configuration: ScribeConfig,
    systemPrompt: String,
    resumeMessages: [ScribeMessage] = [],
    sessionPersistenceURL: URL,
    sessionId: UUID,
    logger: Logger
  ) async throws -> ChatExitInfo {
    guard isatty(STDIN_FILENO) != 0 else {
      logger.error(
        "chat.session.fail",
        metadata: ["reason": "stdin-not-tty"])
      throw ChatTerminalError.notATerminal
    }
    logger.debug(
      "chat.fullscreen.attach",
      metadata: ["session_file": "\(sessionPersistenceURL.lastPathComponent)"])
    return try await Task { @MainActor () throws -> ChatExitInfo in
      let sessionCreatedAt = Date()
      let host = SlateChatHost(
        configuration: configuration,
        systemPrompt: systemPrompt,
        resumeMessages: resumeMessages,
        sessionPersistenceURL: sessionPersistenceURL,
        sessionId: sessionId,
        sessionCreatedAt: sessionCreatedAt,
        logger: logger
      )
      do {
        return try await host.run()
      } catch Slate.InstallationError.notInteractiveTerminal {
        logger.error(
          "chat.fullscreen.fail",
          metadata: ["reason": "slate-not-interactive"])
        throw ChatTerminalError.slateNotInteractive
      }
    }.value
  }
}
