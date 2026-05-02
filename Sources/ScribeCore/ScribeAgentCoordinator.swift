import Foundation
import ScribeLLM

public enum ScribeAgentCoordinator {

  /// Interactive session; `systemPrompt` is supplied by the CLI (or another host).
  ///
  /// Supply `readUserLine` to integrate with alternate-screen TUIs (for example Slate) or stdin that is not `readLine()`-friendly.
  public static func runInteractive(
    configuration: AgentConfig,
    client: Client,
    systemPrompt: String,
    sink: any ScribeAgentOutput,
    readUserLine: @escaping @Sendable () async -> String?
  ) async throws {
    let cwd = FileManager.default.currentDirectoryPath
    sink.printConfigBanner(
      baseURL: configuration.openAIBaseURL,
      model: configuration.agentModel,
      cwd: cwd
    )

    var history: [Components.Schemas.ChatMessage] = [
      .init(
        role: .system,
        content: systemPrompt,
        name: nil,
        toolCalls: nil,
        toolCallId: nil
      )
    ]

    let harness = AgentHarness(
      output: sink,
      client: client,
      model: configuration.agentModel,
      maxToolRounds: configuration.agentMaxToolRounds
    )

    while true {
      sink.printUserPromptDecoration()
      guard let line = await readUserLine() else { break }
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

      try sink.markModelTurnRunning(true)
      defer {
        try? sink.markModelTurnRunning(false)
      }
      do {
        _ = try await harness.runModelTurn(messages: &history, logger: configuration.makeRequestLogger())
      } catch {
        try sink.printHarnessRunError(error)
        if history.last?.role == .user {
          history.removeLast()
        }
      }
    }
  }

  /// Cooked stdin via blocking ``readLine()`` on a detached task.
  public static func runInteractive(
    configuration: AgentConfig,
    client: Client,
    systemPrompt: String,
    sink: any ScribeAgentOutput
  ) async throws {
    try await runInteractive(
      configuration: configuration,
      client: client,
      systemPrompt: systemPrompt,
      sink: sink,
      readUserLine: {
        await Task.detached(priority: .userInitiated) { readLine() }.value
      }
    )
  }

  /// One user turn over stdin/stdout JSON; suitable for subprocess nesting (agents calling `scribe agent`).
  public static func runAgentIPC(
    configuration: AgentConfig,
    client: Client,
    systemPrompt: String,
    request: ScribeAgentRequest,
    sink: any ScribeAgentOutput
  ) async -> ScribeAgentResponse {
    var history: [Components.Schemas.ChatMessage] = [
      .init(
        role: .system,
        content: systemPrompt,
        name: nil,
        toolCalls: nil,
        toolCallId: nil
      ),
      .init(
        role: .user,
        content: request.message,
        name: nil,
        toolCalls: nil,
        toolCallId: nil
      ),
    ]
    let harness = AgentHarness(
      output: sink,
      client: client,
      model: configuration.agentModel,
      maxToolRounds: configuration.agentMaxToolRounds
    )
    do {
      let outcome = try await harness.runModelTurn(
        messages: &history, logger: configuration.makeRequestLogger())
      if outcome == .hitToolRoundLimit {
        return .failure(
          "Stopped after reaching the configured tool round limit (\(configuration.agentMaxToolRounds))."
        )
      }
      let text = ChatHistory.lastAssistantText(from: history) ?? ""
      return .success(assistant: text)
    } catch let e as AgentAPIError {
      return .failure(e.errorDescription ?? String(describing: e))
    } catch {
      return .failure(String(describing: error))
    }
  }
}
