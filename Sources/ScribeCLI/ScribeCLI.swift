import ArgumentParser
import Foundation
import ProfileRecorderServer
import ScribeCore

@main struct ScribeCLI: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "scribe",
    abstract: "Scribe coding agent",
    discussion: "Version: \(GitVersion.hash)",
    version: "\(GitVersion.hash)"
  )

  @Flag(name: .long, help: "List saved chat sessions (newest first) and exit.")
  var listSessions = false

  @Option(
    name: .long,
    help:
      "Resume a session: file path, full session id, a unique id prefix, or 'latest' (see also --list-sessions)."
  )
  var resume: String?

  func run() async throws {
    #if !os(macOS) && !os(Linux)
    throw ScribeError.configuration(
      key: nil,
      reason: "Scribe is only tested on macOS and Linux.")
    #endif
    let loaded = try await ConfigLoader.load()

    if listSessions {
      let root = try ChatSessionStore.sessionsDirectoryURL(
        sessionsDirectoryPath: loaded.chatSessionsDirectoryPath)
      let files = try ChatSessionStore.listSessionFiles(
        sessionsDirectoryPath: loaded.chatSessionsDirectoryPath)
      guard !files.isEmpty else {
        print("No saved sessions under \(root.path)")
        return
      }
      let home = FileManager.default.homeDirectoryForCurrentUser.path
      for url in files {
        guard let meta = try? ChatSessionStore.loadMetadata(from: url) else { continue }
        let shortId = String(meta.id.uuidString.prefix(8))
        let updatedAt =
          (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
          ?? meta.createdAt
        let when = relativeTime(from: updatedAt)
        let cwd = meta.cwd.replacingOccurrences(of: home, with: "~")

        print(
          formatSessionLine(shortId: shortId, when: when, cwd: cwd, version: meta.scribeVersion ?? "unknown"))
      }
      return
    }

    let cwd = FileManager.default.currentDirectoryPath

    let tools: [any ScribeTool] = [
      ShellTool(), ReadFileTool(), WriteFileTool(), EditFileTool(),
    ]
    let toolNames = tools.map { type(of: $0).name }.joined(separator: ", ")
    let toolHints = tools.compactMap { type(of: $0).promptHint }.joined(separator: "\n\n")

    let systemPrompt = """
      You are Scribe, a coding agent CLI with shell and file tools.

      Prefer doing over asking—use tools first for discovery (list dirs, manifests/docs/README, grep), answer from evidence, and don’t ask permission to read what you can open. When you truly need the user: lead with what you tried and learned, then the single gap. Never “should I look at X?” instead of opening X.

      Git: use `shell` for normal inspection (`git status`, `git diff`, `git log`, branches). Avoid destructive git operations (force push, hard reset, branch deletion) unless the user explicitly requests them.

      Paths behave like a normal shell: relative paths use the working directory printed below; `..` reaches the parent folder and sibling projects that way—if the user mentions such a path, inspect it instead of asking them to relocate or paste files first.

      Tool names must match exactly: \(toolNames).
      Parallel tool calls are fine when they do not depend on each other’s outputs.

      \(toolHints)

      Working directory (relative paths resolve here): \(cwd)
      """

    let scribeConfig = ScribeConfig(
      agentModel: loaded.scribeConfig.agentModel,
      contextWindow: loaded.scribeConfig.contextWindow,
      contextWindowThreshold: loaded.scribeConfig.contextWindowThreshold,
      serverURL: loaded.scribeConfig.serverURL,
      apiKey: loaded.scribeConfig.apiKey,
      tools: tools
    )

    let sessionPersistenceURL: URL
    let resumeArchive: ChatSessionArchive?
    let sessionId: UUID
    if let spec = resume?.trimmingCharacters(in: .whitespacesAndNewlines), !spec.isEmpty {
      sessionPersistenceURL = try ChatSessionStore.resolveResumeURL(
        specifier: spec, sessionsDirectoryPath: loaded.chatSessionsDirectoryPath)
      let archived = try ChatSessionStore.load(from: sessionPersistenceURL)
      resumeArchive = archived
      sessionId = archived.id
    } else {
      sessionId = UUID()
      sessionPersistenceURL = try ChatSessionStore.sessionDirectoryURL(
        sessionId: sessionId, sessionsDirectoryPath: loaded.chatSessionsDirectoryPath)
      resumeArchive = nil
    }

    let log = loaded.makeSessionLogger(sessionId: sessionId)
    let mode = resumeArchive == nil ? "new" : "resume"
    log.notice(
      "chat.session.start",
      metadata: [
        "session_id": "\(sessionId.uuidString)",
        "mode": "\(mode)",
        "scribe_version": "\(GitVersion.hash)",
        "model": "\(scribeConfig.agentModel)",
        "base_url": "\(scribeConfig.serverURL)",
        "api_key": "\(scribeConfig.apiKey == nil ? "none" : "set")",
        "log_level": "\(loaded.logLevel.rawValue)",
        "cwd": "\(cwd)",
        "session_file": "\(sessionPersistenceURL.path)",
        "config_file": "\(loaded.resolvedConfigurationPath)",
      ])
    if let archived = resumeArchive, archived.model != scribeConfig.agentModel {
      log.warning(
        "chat.session.resume.model-mismatch",
        metadata: [
          "archived_model": "\(archived.model)",
          "current_model": "\(scribeConfig.agentModel)",
        ])
    }

    async let _ = ProfileRecorderServer(
      configuration: .parseFromEnvironment()
    ).runIgnoringFailures(logger: log)

    try await SlateChat.runFullscreen(
      configuration: scribeConfig,
      systemPrompt: systemPrompt,
      resumeArchive: resumeArchive,
      sessionPersistenceURL: sessionPersistenceURL,
      sessionId: sessionId,
      log: log
    )
    log.notice("chat.session.end", metadata: ["status": "ok"])
    printExitResumeHint(
      resumeArchive: resumeArchive,
      sessionPersistenceURL: sessionPersistenceURL
    )
  }
}

extension ScribeCLI {
  /// Printed after a normal chat exit regardless of configured `logging.level` (stdout hint only — structured logs stay in log files).
  fileprivate func printExitResumeHint(
    resumeArchive: ChatSessionArchive?,
    sessionPersistenceURL: URL
  ) {
    let stemUUID = UUID(uuidString: sessionPersistenceURL.lastPathComponent)
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

  // MARK: - Session listing helpers

  func relativeTime(from date: Date) -> String {
    let delta = date.timeIntervalSinceNow * -1  // seconds ago
    switch delta {
    case ..<1: return "just now"
    case ..<60: return "\(Int(delta))s ago"
    case ..<3600: return "\(Int(delta / 60))m ago"
    case ..<86400: return "\(Int(delta / 3600))h ago"
    case ..<604800: return "\(Int(delta / 86400))d ago"
    default: return "\(Int(delta / 604800))w ago"
    }
  }

  /// Formats a single session line for `--list-sessions`.  Internal so tests can
  /// verify alignment and content without capturing real stdout.
  func formatSessionLine(
    shortId: String,
    when: String,
    cwd: String,
    version: String
  ) -> String {
    let timeCol = when.padding(toLength: 9, withPad: " ", startingAt: 0)
    return
      "\u{001B}[2m\(timeCol)\u{001B}[0m  \u{001B}[36m\(shortId)\u{001B}[0m  \(cwd)  \u{001B}[2m(\(version))\u{001B}[0m"
  }
}
