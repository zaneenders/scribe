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
  /// When ``resumeArchive`` is `nil`, ``sessionPersistenceURL`` must end with `{uuid}.json` (see ``ChatSessionStore/fileURL(sessionId:configuration:)``).
  ///
  /// - Parameters:
  ///   - resumeArchive: If set, restores model context and redraws approximate transcript (`sessionPersistenceURL` should point at that archive).
  ///   - sessionId: UUID identifying this Scribe invocation (matches the `{uuid}.json` archive
  ///     stem and the `scribe-{uuid}.log` file the `log` parameter writes to).
  ///   - log: Per-session logger created in `Chat.run` via ``ScribeConfig/makeSessionLogger(sessionId:)``.
  ///     All chat events for this invocation funnel into this single `Logger`; we no longer emit
  ///     to a separate diagnostics file.
  ///
  /// ## Logs
  ///
  /// Each `scribe chat` invocation writes **one** log file:
  /// `{logDirectoryPath}/scribe-{sessionId}.log` (the same UUID stem as the
  /// `{sessionId}.json` transcript archive). There is no separate diagnostics file.
  /// Resumed sessions append to the existing log so the full history of the session
  /// ID is preserved.
  ///
  /// Lines are formatted as:
  /// ```
  /// <iso8601-ms> [<level>] event=<ns.name> key1=value1 key2=value2 …
  /// ```
  ///
  /// — for example:
  /// ```
  /// 2026-05-02T17:44:23.123Z [debug] event=chat.user.submit kind=queue chars=42 newlines=0 replacing=false model_busy=true
  /// ```
  ///
  /// The leading timestamp makes it easy to align input events against agent stream
  /// timing when debugging input lag, hangs, or surprising state transitions.
  ///
  /// ### Chat-host events (`SlateChatHost`)
  ///
  /// | Event | Sample fields | When it fires |
  /// |---|---|---|
  /// | `chat.session.start` | `session_id model mode max_tool_rounds log_level cwd session_file config_file` | First line of the file — emitted by `Chat.run` once the session id is known. `mode` is `new` or `resume`. |
  /// | `chat.session.resume.model-mismatch` | `archived_model current_model` | Resuming a session saved with a different model than the current config. |
  /// | `chat.fullscreen.attach` | `session_file` | `SlateChat.runFullscreen` accepted the TTY and is starting the host. |
  /// | `chat.fullscreen.fail` | `reason=slate-not-interactive` | Slate refused the terminal. |
  /// | `chat.user.input.shift-enter` | `source buffer_chars has_queue` | Soft newline inserted (Shift+Enter / Alt+Enter / Ctrl+J etc.). |
  /// | `chat.user.input.paste-begin` / `paste-end` | `buffer_chars` | Bracketed-paste boundaries — handy when correlating large multi-line submits with subsequent submit/queue events. |
  /// | `chat.user.submit kind=immediate` | `chars newlines model_busy=false` | Enter sent the buffer straight to the agent (idle path — first message, between turns, etc.). |
  /// | `chat.user.submit kind=queue` | `chars newlines replacing model_busy=true` | Enter parked the buffer in the queued tray while the agent is busy. `replacing=true` means a previously queued message was overwritten. |
  /// | `chat.user.submit kind=interrupt-and-send` | `chars newlines model_busy` | Enter on an empty buffer with a queued message: interrupted the agent (if busy) and dispatched the queued text. |
  /// | `chat.user.submit kind=noop` | `reason model_busy` | Enter pressed with nothing to submit. |
  /// | `chat.user.ctrl-c action=recall-queue` | `queue_chars model_busy` | Ladder step 1 — queued text pulled back into the input box. |
  /// | `chat.user.ctrl-c action=interrupt-agent` | `model_busy=true` | Ladder step 2 — interrupt requested. |
  /// | `chat.user.ctrl-c action=exit` | `model_busy=false` | Ladder step 3 — exit the chat. |
  /// | `chat.user.ctrl-d action=exit` | — | EOF press at any time. |
  /// | `chat.user.eof` | `reason=stdin-closed` | `readUserLine` returned `nil` (stdin closed). |
  /// | `chat.user.exit-command` | — | User typed `exit` as a submission. |
  /// | `chat.user.empty-skip` | — | Empty submission ignored by the coordinator. |
  /// | `chat.queue.auto-flush` | `trigger=busy-to-idle chars` | Agent finished its turn naturally with a queued message in the tray; the queue is being handed off to the coordinator. |
  /// | `chat.render.slow` | `elapsed_ms prepare_ms submit_ms flat_rows cols rows model_busy queue_chars buffer_chars` | A render frame's on-actor portion took ≥50 ms. `prepare_ms` is transcript flatten + layout; `submit_ms` is grid build + encode + writer submit (the actual tty drain happens off-actor and is **not** included). |
  /// | `chat.persist.save` | `messages path` | Conversation snapshot persisted to disk. |
  /// | `chat.persist.fail` | `path err` | Persistence write failed. |
  /// | `chat.coordinator.start` | `messages resumed` | Coordinator entered its prompt loop. |
  /// | `chat.coordinator.end` | `transcript_messages turns` | Coordinator left its prompt loop normally. |
  /// | `chat.coordinator.fail` | `err` | Coordinator task threw out of `runInteractive`. |
  /// | `chat.session.end` | `status=ok` | Last line of the file. |
  static func runFullscreen(
    configuration: ScribeConfig,
    systemPrompt: String,
    resumeMessages: [ScribeMessage] = [],
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
      let sessionCreatedAt = Date()
      let host = SlateChatHost(
        configuration: configuration,
        systemPrompt: systemPrompt,
        resumeMessages: resumeMessages,
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
