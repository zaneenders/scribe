import Foundation
import Logging
import ScribeCore
import SlateCore
import SystemPackage

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

internal enum ChatTerminalError: Error, LocalizedError {

  case notATerminal

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

  static func runFullscreen(
    configuration: ScribeConfig,
    systemPrompt: String,
    resumeMessages: [ScribeMessage] = [],
    sessionDirectory: FilePath,
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
      metadata: ["session_file": "\(sessionDirectory.lastComponent?.string ?? sessionDirectory.string)"])

    let sessionCreatedAt = Date()
    let isNewSession = resumeMessages.isEmpty
    if !isNewSession, resumeMessages.first?.role != .system {
      throw ScribeError.sessionCorrupted(
        reason: "Resumed conversation must begin with a system message.")
    }

    let cwdString = FilePath.currentDirectory.string
    let persister = try await FileSessionPersister.open(
      sessionId: sessionId,
      directory: sessionDirectory,
      sessionCreatedAt: sessionCreatedAt,
      isNewSession: isNewSession,
      model: configuration.agentModel,
      cwd: cwdString,
      baseURL: configuration.serverURL,
      scribeVersion: GitVersion.hash,
      logger: logger
    )
    return try await Task { @MainActor () throws -> ChatExitInfo in
      var document = SessionDocument(
        sessionId: sessionId,
        directory: sessionDirectory,
        logger: logger
      )
      if isNewSession {
        let system = ScribeMessage(role: .system, content: systemPrompt)
        try await persister.append([system])
        document.append([system])
      } else {
        document.append(resumeMessages)
      }
      let messageQueues = SessionMessageQueues()
      let host = SlateChatHost(
        configuration: configuration,
        harness: try SessionHarness(
          configuration: configuration,
          document: consume document,
          persister: persister,
          logger: logger,
          messageQueues: messageQueues
        ),
        messageQueues: messageQueues,
        sessionDirectory: sessionDirectory,
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
