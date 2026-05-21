import Foundation
import Logging
import ScribeCore

/// One-shot agent that condenses a slice of a session's transcript into a
/// short prose summary, used by `/tldr` when the user wants to collapse
/// a long agent loop before continuing.
enum SessionSummarizer {

  private static let summarizerSystemPrompt = """
    You are describing the PATH an AI coding assistant took through a slice \
    of a coding session. The transcript below shows the assistant's actions \
    — tool calls (file reads, greps, shell commands, edits), tool results, \
    and any inline reasoning — in response to a user request. Your output \
    will replace this slice in the session log so future turns have a \
    record of *how* the assistant arrived where it did.

    The final answer or conclusion the assistant produced is preserved \
    elsewhere in the session — DO NOT restate it. Write about the journey, \
    not the destination. If you find yourself rewriting the assistant's \
    final response, stop and describe the discovery work instead.

    Cover concretely, in first person as the assistant:
    - Which files / directories were read (cite paths; include line ranges \
      when the read was narrow)
    - Searches / greps run and what they were looking for
    - Shell commands executed and what they revealed
    - Edits or writes that landed (paths, what changed at a high level)
    - Decisions made along the way and the evidence behind them
    - Dead ends, blockers, or paths abandoned

    Format: 3–8 sentences of plain prose, no bullets, no headers, no \
    section titles. Write as the assistant in the first person: \
    "I read X.swift:10–80 to check Y, then ran `grep Foo` which surfaced \
    Z, so I edited A.swift to ..." Keep it tight and concrete — file \
    paths and command shapes beat adjectives.
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
