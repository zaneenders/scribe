import Foundation
import Logging
import OpenAPIRuntime
import ScribeLLMCodex

/// Parses the Codex SSE stream into AgentEvent values.
/// Mirrors the structure of `StreamProcessor` but handles the
/// Codex Responses API event types instead of Chat Completions chunks.
struct CodexStreamProcessor<AO: AbortObserver> {
  private let onEvent: (AgentEvent) -> Void
  private let logger: Logger
  private let abortObserver: AO
  private let clock = ContinuousClock()

  private(set) var lastUsage: ScribeLLMCodex.Components.Schemas.CodexUsage?
  private(set) var streamStarted = false
  private(set) var streamSection: AssistantStreamSection?
  private(set) var firstStreamContentAt: ContinuousClock.Instant?
  private(set) var decodedChunkCount = 0
  private(set) var isIncomplete = false
  private(set) var incompleteReason: String?
  private var receivedTerminalEvent = false
  let streamWallStart: ContinuousClock.Instant

  init(
    onEvent: @escaping (AgentEvent) -> Void,
    logger: Logger,
    abortObserver: AO,
    streamWallStart: ContinuousClock.Instant
  ) {
    self.onEvent = onEvent
    self.logger = logger
    self.abortObserver = abortObserver
    self.streamWallStart = streamWallStart
  }

  mutating func process(
    httpBody: HTTPBody,
    httpStart: ContinuousClock.Instant,
    turn: inout CodexAssistantTurn
  ) async throws {
    let sseStream = httpBody.asDecodedServerSentEvents(
      while: { $0 != HTTPBody.ByteChunk("[DONE]".utf8) }
    )

    var loggedFirstChunk = false

    do {
      for try await sse in sseStream {
        if abortObserver.isAborted() {
          logger.notice("agent.stream.abort", metadata: ["where": "mid-stream-codex"])
          if streamStarted {
            onEvent(.output(.finalized))
          }
          throw AgentTurnInterruptedError()
        }
        guard let raw = sse.data?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty
        else { continue }
        if raw == "[DONE]" { break }

        guard let data = raw.data(using: .utf8),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let eventType = json["type"] as? String
        else {
          logger.warning("agent.stream.unreadable-codex-chunk", metadata: ["raw_prefix": "\(raw.prefix(120))"])
          continue
        }

        decodedChunkCount += 1
        if !loggedFirstChunk {
          loggedFirstChunk = true
          logger.debug(
            "agent.stream.first-chunk-codex", metadata: ["ttfb_ms": "\((clock.now - httpStart) / .milliseconds(1))"])
        }

        // Handle terminal events
        switch eventType {
        case "response.completed":
          receivedTerminalEvent = true
          if let response = json["response"] as? [String: Any] {
            turn.responseId = response["id"] as? String
            if let usage = response["usage"] as? [String: Any] {
              lastUsage = parseCodexUsage(usage)
            }
          }
          if streamStarted || !turn.text.isEmpty || !turn.resolvedToolCalls().isEmpty {
            onEvent(.output(.finalized))
          } else {
            onEvent(.output(.empty))
          }
          return

        case "response.incomplete":
          receivedTerminalEvent = true
          if let response = json["response"] as? [String: Any] {
            turn.responseId = response["id"] as? String
            if let usage = response["usage"] as? [String: Any] {
              lastUsage = parseCodexUsage(usage)
            }
            if let incompleteDetails = response["incomplete_details"] as? [String: Any] {
              incompleteReason = incompleteDetails["reason"] as? String
            }
          }
          isIncomplete = true
          if streamStarted || !turn.text.isEmpty || !turn.resolvedToolCalls().isEmpty {
            onEvent(.output(.finalized))
          } else {
            onEvent(.output(.empty))
          }
          return

        case "response.failed":
          receivedTerminalEvent = true
          throw codexStreamError(from: json, fallback: "Codex response failed")

        case "error":
          receivedTerminalEvent = true
          throw codexStreamError(from: json, fallback: "Codex stream error")

        // Content events
        case "response.output_text.delta":
          if let delta = json["delta"] as? String {
            markStreamStarted()
            emitAnswerDelta(delta)
            turn.text += delta
          }

        case "response.refusal.delta":
          if let delta = json["delta"] as? String {
            markStreamStarted()
            emitAnswerDelta(delta)
            turn.text += delta
          }

        case "response.reasoning_text.delta":
          if let delta = json["delta"] as? String {
            markStreamStarted()
            emitReasoningDelta(delta)
            turn.reasoningText += delta
          }

        case "response.reasoning_summary_text.delta":
          if let delta = json["delta"] as? String {
            markStreamStarted()
            emitReasoningDelta(delta)
            turn.reasoningText += delta
          }

        case "response.function_call_arguments.delta":
          if let delta = json["delta"] as? String,
            let outputIndex = json["output_index"] as? Int
          {
            markStreamStarted()
            emitToolCallDelta(outputIndex: outputIndex, delta: delta)
            turn.applyToolCallDelta(outputIndex: outputIndex, delta: delta)
          }

        case "response.output_item.done":
          if let item = json["item"] as? [String: Any],
            let outputIndex = json["output_index"] as? Int
          {
            if let itemType = item["type"] as? String {
              switch itemType {
              case "function_call":
                let itemId = item["id"] as? String ?? ""
                let callId = item["call_id"] as? String ?? ""
                let name = item["name"] as? String ?? ""
                let args = item["arguments"] as? String ?? "{}"
                turn.finalizeToolCall(
                  outputIndex: outputIndex,
                  callID: callId,
                  itemID: itemId,
                  name: name,
                  arguments: args)
              case "message":
                // text is already captured via deltas
                break
              case "reasoning":
                // reasoning is already captured via deltas
                break
              default:
                break
              }
            }
          }

        case "response.created":
          if let resp = json["response"] as? [String: Any] {
            turn.responseId = resp["id"] as? String
          }

        default:
          // Unknown events are silently skipped
          break
        }
      }
    } catch is AgentTurnInterruptedError {
      throw AgentTurnInterruptedError()
    } catch {
      logger.error("agent.stream.error.codex", metadata: ["err": "\(String(describing: error))"])
      throw error
    }

    if !receivedTerminalEvent {
      isIncomplete = true
      incompleteReason = "Stream ended without terminal event"
    }
    if streamStarted {
      onEvent(.output(.finalized))
    } else {
      onEvent(.output(.empty))
    }
  }

  // MARK: - Helpers

  private func codexStreamError(
    from event: [String: Any],
    fallback: String
  ) -> ScribeError {
    let response = event["response"] as? [String: Any]
    let nestedError =
      (response?["error"] as? [String: Any])
      ?? (event["error"] as? [String: Any])

    let message = firstNonEmptyString(
      nestedError?["message"],
      event["message"],
      response?["message"]
    )
    let code = firstNonEmptyString(
      nestedError?["code"],
      event["code"],
      response?["code"]
    )
    let errorType = firstNonEmptyString(
      nestedError?["type"],
      event["error_type"],
      response?["error_type"]
    )
    let responseID = firstNonEmptyString(response?["id"], event["response_id"])

    var description = message ?? fallback
    let details = [
      code.map { "code: \($0)" },
      errorType.map { "type: \($0)" },
      responseID.map { "response: \($0)" },
    ].compactMap { $0 }
    if !details.isEmpty {
      description += " (\(details.joined(separator: ", ")))"
    }

    let rawEvent = compactJSON(event, limit: 4_000)
    if message == nil, let rawEvent {
      description += " — event: \(rawEvent)"
    }

    logger.error(
      "agent.stream.provider-error.codex",
      metadata: [
        "event_type": "\(event["type"] as? String ?? "unknown")",
        "message": "\(message ?? "missing")",
        "code": "\(code ?? "missing")",
        "error_type": "\(errorType ?? "missing")",
        "response_id": "\(responseID ?? "missing")",
        "decoded_chunks": "\(decodedChunkCount)",
        "stream_started": "\(streamStarted)",
        "raw_event": "\(rawEvent ?? "unavailable")",
      ])
    return .generic(description)
  }

  private func firstNonEmptyString(_ values: Any?...) -> String? {
    values.lazy.compactMap { value in
      guard let string = value as? String else { return nil }
      let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed.isEmpty ? nil : trimmed
    }.first
  }

  private func compactJSON(_ object: [String: Any], limit: Int = 1_000) -> String? {
    guard JSONSerialization.isValidJSONObject(object),
      let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    else { return nil }
    let text = String(decoding: data, as: UTF8.self)
    return text.count <= limit ? text : "\(text.prefix(limit))…"
  }

  private mutating func markStreamStarted() {
    if firstStreamContentAt == nil { firstStreamContentAt = clock.now }
    streamStarted = true
  }

  private mutating func emitAnswerDelta(_ text: String) {
    if case .some(.answer) = streamSection {
      // already in answer section
    } else {
      onEvent(.output(.sectionStarted(.answer, previous: streamSection)))
      streamSection = .answer
    }
    onEvent(.output(.text(.answer, text)))
  }

  private mutating func emitReasoningDelta(_ text: String) {
    if case .some(.reasoning) = streamSection {
      // already in reasoning section
    } else {
      onEvent(.output(.sectionStarted(.reasoning, previous: streamSection)))
      streamSection = .reasoning
    }
    onEvent(.output(.text(.reasoning, text)))
  }

  private mutating func emitToolCallDelta(outputIndex: Int, delta: String) {
    // Tool call deltas are collected, not emitted as text.
    // The tool_call event is emitted by the agent loop when tool calls are resolved.
  }

  private func parseCodexUsage(_ raw: [String: Any]) -> ScribeLLMCodex.Components.Schemas.CodexUsage {
    var usage = Components.Schemas.CodexUsage()
    usage.inputTokens = raw["input_tokens"] as? Int
    usage.outputTokens = raw["output_tokens"] as? Int
    usage.totalTokens = raw["total_tokens"] as? Int
    if let details = raw["input_tokens_details"] as? [String: Any] {
      var inputDetails = Components.Schemas.CodexUsage.InputTokensDetailsPayload()
      inputDetails.cachedTokens = details["cached_tokens"] as? Int
      inputDetails.cacheWriteTokens = details["cache_write_tokens"] as? Int
      usage.inputTokensDetails = inputDetails
    }
    if let details = raw["output_tokens_details"] as? [String: Any] {
      var outputDetails = Components.Schemas.CodexUsage.OutputTokensDetailsPayload()
      outputDetails.reasoningTokens = details["reasoning_tokens"] as? Int
      usage.outputTokensDetails = outputDetails
    }
    return usage
  }
}

// MARK: - Codex Assistant Turn

/// Accumulates streaming content from the Codex Responses API.
struct CodexAssistantTurn {
  var text = ""
  var reasoningText = ""
  var responseId: String?
  private var toolCallsByIndex: [Int: PartialCodexToolCall] = [:]

  struct PartialCodexToolCall {
    var callID: String?
    var itemID: String?
    var name: String?
    var arguments: String

    init(
      callID: String? = nil,
      itemID: String? = nil,
      name: String? = nil,
      arguments: String = ""
    ) {
      self.callID = callID
      self.itemID = itemID
      self.name = name
      self.arguments = arguments
    }
  }

  mutating func applyToolCallDelta(outputIndex: Int, delta: String) {
    var acc = toolCallsByIndex[outputIndex] ?? PartialCodexToolCall()
    acc.arguments += delta
    toolCallsByIndex[outputIndex] = acc
  }

  mutating func finalizeToolCall(
    outputIndex: Int,
    callID: String,
    itemID: String,
    name: String,
    arguments: String
  ) {
    var acc = toolCallsByIndex[outputIndex] ?? PartialCodexToolCall()
    acc.callID = callID
    acc.itemID = itemID
    acc.name = name
    // Use the final arguments if we didn't get deltas, or if the final is complete
    if acc.arguments.isEmpty || arguments.count > acc.arguments.count {
      acc.arguments = arguments
    }
    toolCallsByIndex[outputIndex] = acc
  }

  func resolvedToolCalls() -> [ToolInvocation] {
    toolCallsByIndex.keys.sorted().compactMap { key in
      guard let t = toolCallsByIndex[key],
        let callID = t.callID,
        let itemID = t.itemID,
        let name = t.name
      else { return nil }
      let identifiers = CodexToolCallIdentifiers(callID: callID, itemID: itemID)
      return ToolInvocation(id: identifiers.encoded, name: name, arguments: t.arguments)
    }
  }
}
