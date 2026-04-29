import ArgumentParser
import Foundation
import ScribeCore
import ScribeLLM

struct Chat: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "chat",
    abstract: "Interactive terminal session (default)"
  )

  func run() async throws {
    let config = try await AgentConfig.load()
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

      Working directory (relative paths resolve here): \(cwd)
      """
    let sink = TerminalScribeOutput()
    try await ScribeAgentCoordinator.runInteractive(
      configuration: config,
      client: client,
      systemPrompt: systemPrompt,
      sink: sink
    )
  }
}
