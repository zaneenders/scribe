import ArgumentParser
import Foundation
import ScribeCore
import ScribeLLM

struct Chat: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "chat",
    abstract: "Interactive terminal session (default)"
  )

  @Flag(name: .long, help: "List saved chat sessions (newest first) and exit.")
  var sessions = false

  @Option(
    name: .long,
    help:
      "Resume a session: file path, full session id, a unique id prefix, or 'latest' (see also --sessions)."
  )
  var resume: String?

  func run() async throws {
    let config = try await AgentConfig.load()

    if sessions {
      let root = try ChatSessionStore.sessionsDirectoryURL(configuration: config)
      let files = try ChatSessionStore.listSessionFiles(configuration: config)
      guard !files.isEmpty else {
        print("No saved sessions under \(root.path)")
        return
      }
      let formatter = ISO8601DateFormatter()
      formatter.formatOptions = [.withInternetDateTime]
      for url in files {
        guard let archive = try? ChatSessionStore.load(from: url) else { continue }
        let updated = formatter.string(from: archive.updatedAt)
        print("\(archive.id.uuidString)  updated \(updated)  model \(archive.model)  msgs \(archive.messages.count)")
        print("  cwd  \(archive.cwd)")
        print("  path \(url.path)\n")
      }
      return
    }

    let base = config.openAIBaseURL
    let token = config.openAIAPIKey
    guard let serverURL = URL(string: base) else {
      throw AgentAPIError(
        description:
          "Invalid \(ScribeConfigBinding.openAIBaseURL.description) in `scribe-config.json`. Use host only, no `/v1` (e.g. http://127.0.0.1:11434 for Ollama)."
      )
    }
    let client = OpenAICompatibleClient.make(serverURL: serverURL, bearerToken: token)
    let cwd = FileManager.default.currentDirectoryPath
    let systemPrompt = """
      You are Scribe, a coding agent CLI with shell and file tools.

      Prefer doing over asking—use tools first for discovery (list dirs, manifests/docs/README, grep), answer from evidence, and don’t ask permission to read what you can open. When you truly need the user: lead with what you tried and learned, then the single gap. Never “should I look at X?” instead of opening X.

      Git: use `shell` for normal inspection (`git status`, `git diff`, `git log`, branches). Avoid destructive git operations (force push, hard reset, branch deletion) unless the user explicitly requests them.

      Paths behave like a normal shell: relative paths use the working directory printed below; `..` reaches the parent folder and sibling projects that way—if the user mentions such a path, inspect it instead of asking them to relocate or paste files first.

      Tool names must match exactly: shell, read_file, write_file, edit_file.
      Parallel tool calls are fine when they do not depend on each other’s outputs.

      For `read_file`, prefer paginating large files: pass `offset` (1-indexed start line) and `limit` (max lines, default 2000) and use the returned `end_line` + 1 as the next `offset` if `truncated` is true. This keeps the conversation history small.

      Working directory (relative paths resolve here): \(cwd)
      """

    let sessionPersistenceURL: URL
    let resumeArchive: ChatSessionArchive?
    let sessionId: UUID
    if let spec = resume?.trimmingCharacters(in: .whitespacesAndNewlines), !spec.isEmpty {
      sessionPersistenceURL = try ChatSessionStore.resolveResumeURL(
        specifier: spec, configuration: config)
      let archived = try ChatSessionStore.load(from: sessionPersistenceURL)
      resumeArchive = archived
      sessionId = archived.id
    } else {
      sessionId = UUID()
      sessionPersistenceURL = try ChatSessionStore.fileURL(
        sessionId: sessionId, configuration: config)
      resumeArchive = nil
    }

    let log = config.makeSessionLogger(sessionId: sessionId)
    let mode = resumeArchive == nil ? "new" : "resume"
    log.notice(
      """
      event=chat.session.start \
      session_id=\(sessionId.uuidString) \
      mode=\(mode) \
      model=\(config.agentModel) \
      base_url=\(config.openAIBaseURL) \
      api_key=\(config.openAIAPIKey == nil ? "none" : "set") \
      max_tool_rounds=\(config.agentMaxToolRounds) \
      log_level=\(config.logLevel.rawValue) \
      cwd=\(cwd) \
      session_file=\(sessionPersistenceURL.path) \
      config_file=\(config.resolvedConfigurationPath)
      """
    )
    if let archived = resumeArchive, archived.model != config.agentModel {
      log.warning(
        """
        event=chat.session.resume.model-mismatch \
        archived_model=\(archived.model) \
        current_model=\(config.agentModel)
        """
      )
    }

    try await SlateChat.runFullscreen(
      configuration: config,
      client: client,
      systemPrompt: systemPrompt,
      resumeArchive: resumeArchive,
      sessionPersistenceURL: sessionPersistenceURL,
      sessionId: sessionId,
      log: log
    )
    log.notice("event=chat.session.end status=ok")
    printExitResumeHint(
      resumeArchive: resumeArchive,
      sessionPersistenceURL: sessionPersistenceURL
    )
  }
}

extension Chat {
  /// Printed after a normal chat exit regardless of configured ``logging.level`` (stdout hint only — structured logs stay in log files).
  fileprivate func printExitResumeHint(
    resumeArchive: ChatSessionArchive?,
    sessionPersistenceURL: URL
  ) {
    let stemUUID = UUID(uuidString: sessionPersistenceURL.deletingPathExtension().lastPathComponent)
    let specifier: String
    if let archived = resumeArchive {
      specifier = archived.id.uuidString
    } else if let stem = stemUUID {
      specifier = stem.uuidString
    } else {
      specifier = "'" + Self.escapeForSingleQuotedPOSIXPath(sessionPersistenceURL.path) + "'"
    }
    let binaryName =
      CommandLine.arguments.first.map { NSString(string: $0).lastPathComponent } ?? "scribe"
    let hint = "\(binaryName) --resume \(specifier)"
    guard let text = ("Resume with: \(hint)\n").data(using: .utf8) else { return }
    try? FileHandle.standardError.write(contentsOf: text)
  }

  private static func escapeForSingleQuotedPOSIXPath(_ path: String) -> String {
    path.replacingOccurrences(of: "'", with: "'\"'\"'")
  }
}
