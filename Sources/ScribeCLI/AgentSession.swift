import Foundation
import OpenAPIAsyncHTTPClient

enum AgentSession {
  private static func systemPrompt(workspaceRoot: String) -> [Components.Schemas.ChatMessage] {
    [
      .init(
        role: .system,
        content: """
          You are Scribe, a coding agent CLI with shell and file tools.

          Prefer doing over asking—use tools first for discovery (list dirs, manifests/docs/README, grep), answer from evidence, and don’t ask permission to read what you can open. When you truly need the user: lead with what you tried and learned, then the single gap. Never “should I look at X?” instead of opening X.

          Git: use `shell` for normal inspection (`git status`, `git diff`, `git log`, branches). Avoid destructive git operations (force push, hard reset, branch deletion) unless the user explicitly requests them.

          Paths behave like a normal shell: relative paths use the working directory printed below; `..` reaches the parent folder and sibling projects that way—if the user mentions such a path, inspect it instead of asking them to relocate or paste files first.

          Tool names must match exactly: shell, read_file, write_file, edit_file.
          Parallel tool calls are fine when they do not depend on each other’s outputs.

          Working directory (relative paths resolve here): \(workspaceRoot)
          """,
        name: nil,
        toolCalls: nil,
        toolCallId: nil
      )
    ]
  }

  static func run() async throws {
    let config = try await AgentConfig.load()
    let base = config.openAIBaseURL
    let token = config.openAIAPIKey
    let maxRounds = config.agentMaxToolRounds

    guard let serverURL = URL(string: base) else {
      throw AgentAPIError(
        description:
          "Invalid \(ScribeConfigBinding.openAIBaseURL.description) in `scribe-config.json`. Use host only, no `/v1` (e.g. http://127.0.0.1:11434 for Ollama)."
      )
    }

    let client = Client(
      serverURL: serverURL,
      transport: AsyncHTTPClientTransport(),
      middlewares: [BearerTokenMiddleware(token: token)]
    )

    let model = config.agentModel
    let cwd = FileManager.default.currentDirectoryPath

    let labelGray = ANSI.grayDark
    let valueGray = ANSI.grayLight
    print(
      "\(labelGray)LLM:\(ANSI.reset) \(valueGray)\(base)\(ANSI.reset)\n\(labelGray)Model:\(ANSI.reset) \(valueGray)\(model)\(ANSI.reset)\n\(labelGray)CWD:\(ANSI.reset) \(valueGray)\(cwd)\(ANSI.reset)\n"
    )

    var history: [Components.Schemas.ChatMessage] = systemPrompt(workspaceRoot: cwd)
    let harness = AgentHarness(client: client, model: model, maxToolRounds: maxRounds)

    while true {
      try FileHandle.standardOutput.write(
        contentsOf: Data("\(ANSI.orange)you:\(ANSI.reset) ".utf8))
      guard let line = readLine() else { break }
      let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
      if trimmed == "exit" { break }
      if trimmed.isEmpty { continue }

      history.append(
        .init(
          role: .user,
          content: trimmed,
          name: nil,
          toolCalls: nil,
          toolCallId: nil
        )
      )

      do {
        try await harness.runModelTurn(messages: &history)
      } catch {
        print("\(ANSI.red)error: \(error)\(ANSI.reset)\n")
        if history.last?.role == .user {
          history.removeLast()
        }
      }
    }
  }
}
