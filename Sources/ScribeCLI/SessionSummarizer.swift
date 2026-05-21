import Foundation
import Logging
import ScribeCore

/// One-shot agent that condenses a slice of a session's transcript into a
/// short prose summary, used by `/summarize` when the user wants to collapse
/// a long agent loop before continuing.
enum SessionSummarizer {

  private static let summarizerSystemPrompt = """
    You are summarizing the work an AI coding assistant just performed. The \
    transcript below contains the assistant's actions (its text, the tools it \
    called, and the tool outputs) in response to a user request. Produce a \
    concise summary that can replace the transcript so a future conversation \
    can continue from this point without losing the key information.

    Cover:
    - The task or question the assistant was addressing
    - What was tried or executed (file paths, commands, decisions)
    - The outcome or current state
    - Any open questions, blockers, or next steps

    Keep it tight: 3 to 8 sentences. Plain prose, no bullets, no headers.
    """

  /// Render a slice of session messages into a transcript-like string that
  /// the summarizer reads as a single user message. System and user roles in
  /// the slice are included for context (helps when the slice straddles a
  /// user turn), but tool calls and tool results are formatted inline so the
  /// summarizer sees the full action sequence.
  static func renderSlice(_ messages: [ScribeMessage]) -> String {
    var lines: [String] = []
    for msg in messages {
      switch msg.role {
      case .system:
        let t = msg.content
        if !t.isEmpty { lines.append("System: \(t)") }
      case .user:
        let t = msg.content
        if !t.isEmpty { lines.append("User: \(t)") }
      case .assistant:
        let t = msg.content
        if !t.isEmpty { lines.append("Assistant: \(t)") }
        if let calls = msg.toolCalls {
          for call in calls {
            lines.append("  [tool call: \(call.name) \(call.arguments)]")
          }
        }
      case .tool:
        let t = msg.content
        let label = msg.name ?? "tool"
        lines.append("Tool result (\(label)): \(t)")
      }
    }
    return lines.joined(separator: "\n\n")
  }

  /// Summarize the given slice of session messages using a one-shot agent
  /// with no tools. The current `configuration`'s model and server are
  /// reused; only the tool list is cleared.
  static func summarize(
    slice: [ScribeMessage],
    configuration: ScribeConfig,
    log: Logger
  ) async throws -> String {
    let summarizerConfig = ScribeConfig(
      agentModel: configuration.agentModel,
      contextWindow: configuration.contextWindow,
      contextWindowThreshold: configuration.contextWindowThreshold,
      serverURL: configuration.serverURL,
      apiKey: configuration.apiKey,
      tools: [],
      workingDirectory: configuration.workingDirectory,
      reasoningEnabled: configuration.reasoningEnabled
    )
    let agent = try ScribeAgent(
      configuration: summarizerConfig,
      systemPrompt: summarizerSystemPrompt
    )
    let rendered = renderSlice(slice)
    let userPrompt = "Transcript to summarize:\n\n\(rendered)"

    log.debug(
      "event=summarize.start",
      metadata: [
        "slice_messages": "\(slice.count)",
        "transcript_chars": "\(rendered.count)",
      ])

    let turn = await agent.stream(userPrompt, log: log)
    for await _ in turn.events { /* drain — we only need the result */ }
    let result = try await turn.result.value
    // The last assistant message contains the summary; storage holds
    // [system, user, assistant] after a successful turn.
    guard let summary = result.messages.last(where: { $0.role == .assistant })?.content,
      !summary.isEmpty
    else {
      throw ScribeError.generic("Summarizer produced no assistant text.")
    }
    log.info(
      "event=summarize.end",
      metadata: ["summary_chars": "\(summary.count)"])
    return summary
  }
}
