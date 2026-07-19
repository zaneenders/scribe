import Foundation
import ScribeLLM

struct RequestBudgetEstimate: Equatable, Sendable {
  let estimatedInputTokens: Int
  let inputTokenLimit: Int
  let textBytes: Int
  let imageCount: Int
  let toolDefinitionBytes: Int

  var exceedsLimit: Bool { estimatedInputTokens > inputTokenLimit }
}

/// A deliberately conservative request-size estimate used to catch obviously unsafe requests
/// before they reach a provider. This is not a tokenizer: UTF-8 text and tool schemas are charged
/// at one token per three bytes, with fixed overhead for messages and images.
func estimateRequestBudget(
  messages: [Components.Schemas.ChatMessage],
  tools: [Components.Schemas.ChatTool],
  contextWindow: Int
) -> RequestBudgetEstimate? {
  guard contextWindow > 0 else { return nil }

  var textBytes = 0
  var imageCount = 0
  var structuralTokens = messages.count * 16

  for message in messages {
    if let content = message.content {
      switch content {
      case .case1(let text):
        textBytes += text.utf8.count
      case .case2(let parts):
        for part in parts {
          switch part {
          case .text(let text):
            textBytes += text.text.utf8.count
          case .imageUrl:
            // Do not count a data URI as ordinary text. Providers tokenize images according to
            // dimensions/detail rather than charging for every base64 character.
            imageCount += 1
          }
        }
      }
    }
    if let calls = message.toolCalls {
      structuralTokens += calls.count * 16
      for call in calls {
        textBytes += (call.function?.name ?? "").utf8.count
        textBytes += (call.function?.arguments ?? "").utf8.count
      }
    }
  }

  let toolDefinitionBytes: Int = tools.reduce(into: 0) { total, tool in
    total += tool.function.name.utf8.count
    total += (tool.function.description ?? "").utf8.count
    if let data = try? JSONSerialization.data(
      withJSONObject: tool.function.parameters.additionalProperties,
      options: [.sortedKeys])
    {
      total += data.count
    }
  }

  let textTokens = (textBytes + toolDefinitionBytes + 2) / 3
  let imageTokens = imageCount * 4_096
  let estimated = textTokens + imageTokens + structuralTokens

  // Keep room for the response and provider-specific framing. Ten percent is enough for large
  // windows; small windows always retain at least 1K tokens, capped at 8K for large models.
  let responseReserve = min(8_192, max(1_024, contextWindow / 10))
  let inputLimit = max(1, contextWindow - responseReserve)
  return RequestBudgetEstimate(
    estimatedInputTokens: estimated,
    inputTokenLimit: inputLimit,
    textBytes: textBytes,
    imageCount: imageCount,
    toolDefinitionBytes: toolDefinitionBytes)
}

/// Compacts tool-generated context until the conservative estimate fits. Returns a recovery
/// description when context changed, nil when it already fit, and throws when user/system content
/// alone is too large to send safely.
func enforceRequestBudget(
  messages: inout [Components.Schemas.ChatMessage],
  newMessages: inout [Components.Schemas.ChatMessage],
  tools: [Components.Schemas.ChatTool],
  contextWindow: Int
) throws -> String? {
  guard var estimate = estimateRequestBudget(
    messages: messages, tools: tools, contextWindow: contextWindow)
  else { return nil }
  guard estimate.exceedsLimit else { return nil }

  let initialEstimate = estimate.estimatedInputTokens
  var compactions: [String] = []

  while estimate.exceedsLimit {
    let before = estimate.estimatedInputTokens
    guard let reason = rollbackContextOverflow(
      messages: &messages,
      newMessages: &newMessages,
      providerDetail:
        "local preflight estimate \(before) tokens exceeds input budget \(estimate.inputTokenLimit)")
    else { break }
    compactions.append(reason)

    guard let next = estimateRequestBudget(
      messages: messages, tools: tools, contextWindow: contextWindow)
    else { break }
    estimate = next
    // Avoid repeatedly replacing an already compact replacement when no meaningful space remains.
    if estimate.estimatedInputTokens >= before { break }
  }

  guard !estimate.exceedsLimit else {
    throw ScribeError.invalidInput(
      message:
        "Request is too large to send safely: estimated \(estimate.estimatedInputTokens) input tokens "
        + "exceeds the preflight budget of \(estimate.inputTokenLimit) for a "
        + "\(contextWindow)-token context window. Start a new session, shorten the prompt, or remove "
        + "large history items.")
  }

  return "request preflight reduced estimated input from \(initialEstimate) to "
    + "\(estimate.estimatedInputTokens) tokens (budget \(estimate.inputTokenLimit)); "
    + compactions.joined(separator: "; ")
}
