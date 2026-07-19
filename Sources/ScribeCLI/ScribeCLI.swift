import ArgumentParser
import Foundation
import ProfileRecorderServer
import ScribeCore
import SystemPackage

enum LoginProvider: String, ExpressibleByArgument {
  case openai
  case moonshot
}

/// Simple API key credential for Moonshot/Kimi Code.
private struct MoonshotCredential: Codable {
  let apiKey: String
}

@main struct ScribeCLI: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "scribe",
    abstract: "Scribe coding agent",
    discussion: "Version: \(GitVersion.hash)",
    version: "\(GitVersion.hash)"
  )

  @Flag(
    name: .long,
    help:
      "List saved chat sessions (newest first) and exit. Filter to current working directory unless --all is passed.")
  var listSessions = false

  @Flag(name: .long, help: "Include sessions from all directories when listing (only meaningful with --list-sessions).")
  var all = false

  @Flag(name: .long, help: "Print Scribe's resolved paths, version, and configuration and exit.")
  var info = false

  @Flag(name: .long, help: "List configured backends and exit.")
  var listProfiles = false

  @Option(
    name: .long,
    help: "Log in to a provider: \"openai\" (ChatGPT subscription) or \"moonshot\" (Kimi Code API key)."
  )
  var login: LoginProvider?

  @Flag(name: .long, help: "Log out of the ChatGPT subscription account.")
  var logout = false

  @Option(
    name: .long,
    help: "Use this named backend profile for this run (does not change the saved selection)."
  )
  var profile: String?

  @Flag(
    name: [.customShort("r")],
    help: "Resume the latest session (preferring current working directory)."
  )
  var resumeLatest = false

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
    let loaded = try await ConfigLoader.load(profileOverride: profile)

    if info {
      printInfo(loaded: loaded)
      return
    }

    if listProfiles {
      printProfiles(loaded: loaded)
      return
    }

    if let provider = login {
      switch provider {
      case .openai:
        try await loginCodex(loaded: loaded)
      case .moonshot:
        try await loginMoonshotApiKey(loaded: loaded)
      }
      return
    }

    if logout {
      try await logoutCodex(loaded: loaded)
      return
    }

    let cwd = FilePath.currentDirectory.string

    if listSessions {
      let root = loaded.paths.sessionsDirectory
      try await ChatSessionStore.ensureSessionsDirectory(root)
      let cwdFilter: String? = all ? nil : cwd
      let files = try await ChatSessionStore.listSessionDirectories(
        sessionsRoot: root,
        cwdFilter: cwdFilter)
      guard !files.isEmpty else {
        if all {
          print("No saved sessions under \(root.string)")
        } else {
          print("No saved sessions under \(root.string) for \(cwd) (use --all to list all sessions)")
        }
        return
      }
      let home = NSHomeDirectory()
      for directory in files {
        guard let meta = try? ChatSessionStore.loadMetadata(from: directory) else { continue }
        let shortId = String(meta.id.uuidString.prefix(8))
        let st = FileStat.stat(directory)
        let updatedAt = st.exists ? st.modificationDate : meta.createdAt
        let when = relativeTime(from: updatedAt)
        let displayCwd = meta.cwd.replacingOccurrences(of: home, with: "~")

        let logFile = loaded.paths.logFile(sessionId: meta.id).string
        let displayLog = logFile.replacingOccurrences(of: home, with: "~")
        print(
          formatSessionLine(
            shortId: shortId,
            when: when,
            cwd: displayCwd,
            logFile: displayLog,
            version: meta.scribeVersion ?? "unknown"))
      }
      return
    }

    let tools: [any ScribeTool] = [
      ShellTool(), ReadFileTool(), WriteFileTool(), EditFileTool(),
    ]
    let toolNames = tools.map { type(of: $0).name }.joined(separator: ", ")
    let toolHints = tools.compactMap { type(of: $0).promptHint }.joined(separator: "\n\n")

    let systemPrompt = """
      You are Scribe, a coding agent CLI with shell and file tools.

      Prefer doing over asking use tools first for discovery (list dirs, manifests/docs/README, grep), answer from evidence, and don't ask permission to read what you can open. When you truly need the user: lead with what you tried and learned, then the single gap. Never "should I look at X?" instead of opening X.

      Git: use `shell` for normal inspection (`git status`, `git diff`, `git log`, branches). Avoid destructive git operations (force push, hard reset, branch deletion) unless the user explicitly requests them.

      Paths behave like a normal shell: relative paths use the working directory printed below; `..` reaches the parent folder and sibling projects that way if the user mentions such a path, inspect it instead of asking them to relocate or paste files first.

      Tool names must match exactly: \(toolNames).
      Parallel tool calls are fine when they do not depend on each other's outputs.

      \(toolHints)

      Scribe's configuration, logs, and sessions live under `~/.scribe/` by default.  If asked to modify or rebuild Scribe itself, clone the source into `~/.scribe/scribe/` from https://github.com/zaneenders/scribe.

      Current working directory (relative paths resolve here): \(cwd)
      """

    let scribeConfig = ScribeConfig(
      agentModel: loaded.scribeConfig.agentModel,
      contextWindow: loaded.scribeConfig.contextWindow,
      contextWindowThreshold: loaded.scribeConfig.contextWindowThreshold,
      serverURL: loaded.scribeConfig.serverURL,
      apiKey: loaded.scribeConfig.apiKey,
      apiType: loaded.apiType,
      tools: tools,
      workingDirectory: cwd,
      reasoningEnabled: loaded.scribeConfig.reasoningEnabled,
      maxTokens: loaded.scribeConfig.maxTokens
    )

    let sessionDirectory: FilePath
    let resumeMetadata: ChatSessionMetadata?
    let resumeMessages: [ScribeMessage]
    let sessionId: UUID

    if resumeLatest {
      let spec = "latest"
      sessionDirectory = try await ChatSessionStore.resolveResumeDirectory(
        specifier: spec,
        sessionsRoot: loaded.paths.sessionsDirectory,
        preferCWD: cwd)
      resumeMetadata = try ChatSessionStore.loadMetadata(from: sessionDirectory)
      resumeMessages = try ChatSessionStore.loadMessages(from: sessionDirectory)
      sessionId = resumeMetadata!.id
    } else if let spec = resume?.trimmingCharacters(in: .whitespacesAndNewlines), !spec.isEmpty {
      sessionDirectory = try await ChatSessionStore.resolveResumeDirectory(
        specifier: spec,
        sessionsRoot: loaded.paths.sessionsDirectory,
        preferCWD: cwd)
      resumeMetadata = try ChatSessionStore.loadMetadata(from: sessionDirectory)
      resumeMessages = try ChatSessionStore.loadMessages(from: sessionDirectory)
      sessionId = resumeMetadata!.id
    } else {
      sessionId = UUID()
      sessionDirectory = try await ChatSessionStore.sessionDirectory(
        sessionId: sessionId, sessionsRoot: loaded.paths.sessionsDirectory)
      resumeMetadata = nil
      resumeMessages = []
    }

    var logger = loaded.makeSessionLogger(sessionId: sessionId)
    let mode = resumeMetadata == nil ? "new" : "resume"
    logger[metadataKey: "mode"] = "\(mode)"
    logger.notice(
      "chat.session.start",
      metadata: [
        "scribe_version": "\(GitVersion.hash)",
        "model": "\(scribeConfig.agentModel)",
        "base_url": "\(scribeConfig.serverURL)",
        "api_key": "\(scribeConfig.apiKey == nil ? "none" : "set")",
        "reasoning": "\(String(describing: scribeConfig.reasoningEnabled))",
        "log_level": "\(loaded.logLevel.rawValue)",
        "cwd": "\(cwd)",
        "session_file": "\(sessionDirectory.string)",
        "config_file": "\(loaded.resolvedConfigurationPath)",
        "profile": "\(loaded.activeProfileName)",
      ])
    if let meta = resumeMetadata, meta.model != scribeConfig.agentModel {
      logger.warning(
        "chat.session.resume.model-mismatch",
        metadata: [
          "archived_model": "\(meta.model)",
          "current_model": "\(scribeConfig.agentModel)",
        ])
    }

    async let _ = ProfileRecorderServer(
      configuration: .parseFromEnvironment()
    ).runIgnoringFailures(logger: logger)

    let exitInfo = try await SlateChat.runFullscreen(
      configuration: scribeConfig,
      systemPrompt: systemPrompt,
      resumeMessages: resumeMessages,
      sessionDirectory: sessionDirectory,
      sessionId: sessionId,
      profileCatalog: loaded.profiles,
      activeProfileName: loaded.activeProfileName,
      scribePaths: loaded.paths,
      logger: logger
    )
    logger.notice("chat.session.end", metadata: ["status": "ok"])
    if let forkedId = exitInfo.forkedToSessionId, let forkedDirectory = exitInfo.forkedToDirectory {
      printForkResumeHint(
        parentSessionId: exitInfo.forkedFromSessionId ?? sessionId,
        forkedSessionId: forkedId,
        forkedSessionDirectory: forkedDirectory
      )
    } else {
      printExitResumeHint(
        sessionId: sessionId,
        sessionDirectory: sessionDirectory
      )
    }
  }

  private func printInfo(loaded: LoadedConfig) {
    let p = loaded.paths
    let home = NSHomeDirectory()

    func abbreviate(_ path: String) -> String {
      if path.hasPrefix(home) {
        return "~" + path.dropFirst(home.count)
      }
      return path
    }

    let scribeHomeEnv = ProcessInfo.processInfo.environment["SCRIBE_HOME"]

    print("Scribe version:  \(GitVersion.hash)")
    print("Data home:       \(abbreviate(p.dataHomePath))")
    print("Config:          \(abbreviate(loaded.resolvedConfigurationPath))")
    print("Active profile:  \(loaded.activeProfileName)")
    print("Selection file:  \(abbreviate(p.activeProfilePath.string))")
    print("Model:           \(loaded.scribeConfig.agentModel)")
    print("API base URL:    \(loaded.apiBaseURL)")
    print(
      "Sessions:        \(abbreviate(p.sessionsDirectoryPath))  ({sessionId}/metadata.json, messages.jsonl, scribe.log)"
    )
    if let env = scribeHomeEnv {
      print("SCRIBE_HOME:     \(env)")
    } else {
      print("SCRIBE_HOME:     (not set)")
    }
  }

  private func printProfiles(loaded: LoadedConfig) {
    for entry in loaded.profiles {
      let marker = entry.name == loaded.activeProfileName ? "*" : " "
      print("\(marker) \(entry.name)")
      print("    model: \(entry.model)")
      print("    api:   \(entry.baseURL)")
    }
    print("")
    print("Saved selection: \(loaded.activeProfileName) (\(loaded.paths.activeProfilePath.string))")
    print("Switch in chat with `/model`, or pass `--profile <name>` for one run.")
  }
}

extension ScribeCLI {

  fileprivate func printExitResumeHint(
    sessionId: UUID,
    sessionDirectory: FilePath
  ) {
    let specifier = sessionId.uuidString
    let binaryName =
      CommandLine.arguments.first.map { NSString(string: $0).lastPathComponent } ?? "scribe"
    let hint = "\(binaryName) -r  # or \(binaryName) --resume \(specifier)"
    guard let text = ("Resume with: \(hint)\n").data(using: .utf8) else { return }
    try? FileHandle.standardError.write(contentsOf: text)
  }

  fileprivate func printForkResumeHint(
    parentSessionId: UUID,
    forkedSessionId: UUID,
    forkedSessionDirectory: FilePath
  ) {
    let binaryName =
      CommandLine.arguments.first.map { NSString(string: $0).lastPathComponent } ?? "scribe"
    let line =
      "Session ended on fork \(forkedSessionId.uuidString) (parent: \(parentSessionId.uuidString))\n"
      + "Resume with: \(binaryName) --resume \(forkedSessionId.uuidString)\n"
    guard let text = line.data(using: .utf8) else { return }
    try? FileHandle.standardError.write(contentsOf: text)
  }

  private static func escapeForSingleQuotedPOSIXPath(_ path: String) -> String {
    path.replacingOccurrences(of: "'", with: "'\"'\"'")
  }

  func relativeTime(from date: Date) -> String {
    let delta = date.timeIntervalSinceNow * -1
    switch delta {
    case ..<1: return "just now"
    case ..<60: return "\(Int(delta))s ago"
    case ..<3600: return "\(Int(delta / 60))m ago"
    case ..<86400: return "\(Int(delta / 3600))h ago"
    case ..<604800: return "\(Int(delta / 86400))d ago"
    default: return "\(Int(delta / 604800))w ago"
    }
  }

  func formatSessionLine(
    shortId: String,
    when: String,
    cwd: String,
    logFile: String,
    version: String
  ) -> String {
    let timeCol = when.padding(toLength: 9, withPad: " ", startingAt: 0)
    return
      "\u{001B}[2m\(timeCol)\u{001B}[0m  \u{001B}[36m\(shortId)\u{001B}[0m  \(cwd)  \u{001B}[2m\(logFile)\u{001B}[0m  \u{001B}[2m(\(version))\u{001B}[0m"
  }

  // MARK: - Login / Logout

  func loginCodex(loaded: LoadedConfig) async throws {
    print("Opening browser for ChatGPT login...")
    print("A browser window should open. Complete login to finish.")
    print("")

    do {
      let credential = try await CodexOAuth.login(
        baseDirectory: URL(fileURLWithPath: loaded.paths.dataHomePath, isDirectory: true)
      )
      print("")
      print("✅ Authenticated successfully!")
      print("   Account ID: \(credential.accountId)")
      print("")
      print("Add a codex profile to your config to use it:")
      print("  api.type: \"codex\"")
      print("  api.baseUrl: \"https://chatgpt.com/backend-api\"")
      print("  agent.model: \"gpt-5.6-sol\"")
    } catch {
      print("")
      print("❌ Login failed: \(error)")
      throw error
    }
  }

  func logoutCodex(loaded: LoadedConfig) async throws {
    do {
      try CodexOAuth.logout(
        baseDirectory: URL(fileURLWithPath: loaded.paths.dataHomePath, isDirectory: true)
      )
      print("✅ Logged out of ChatGPT subscription.")
    } catch {
      print("❌ Logout failed: \(error)")
      throw error
    }
  }

  func loginMoonshotApiKey(loaded: LoadedConfig) async throws {
    print("Enter your Kimi Code API key (starts with sk-kimi-):")
    guard let apiKey = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines),
          !apiKey.isEmpty
    else {
      print("❌ No API key entered.")
      throw ScribeError.invalidInput(message: "No API key entered.")
    }

    guard KimiK3Support.isKimiCodeAPIKey(apiKey) else {
      print("")
      print("❌ That doesn't look like a Kimi Code API key.")
      print("   Kimi Code keys start with \"sk-kimi-\".")
      print("   Moonshot platform keys should be used with api.moonshot.ai in your config.")
      print("   Get a key at: https://kimi.com/code")
      throw ScribeError.invalidInput(message: "Invalid Kimi Code API key format.")
    }

    // Store the API key in a credential file
    let storeURL = URL(fileURLWithPath: loaded.paths.dataHomePath)
      .appendingPathComponent("moonshot-api-key.json")
    let credential = MoonshotCredential(apiKey: apiKey)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(credential)
    try data.write(to: storeURL, options: .atomic)
    try FileManager.default.setAttributes(
      [.posixPermissions: NSNumber(value: 0o600)],
      ofItemAtPath: storeURL.path
    )

    print("")
    print("✅ Kimi Code API key saved!")
    print("   Stored at: \(storeURL.path)")
    print("")
    print("Add a kimi profile to your config to use it:")
    print("  api.type: \"kimi\"")
    print("  api.baseUrl: \"https://api.kimi.com/coding\"")
    print("  agent.model: \"kimi-k3-thinking\"")
    print("")
    print("Or the key will be auto-detected for profiles with api.type: \"kimi\".")
  }
}
