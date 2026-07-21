import Foundation
import Logging
import ScribeLLM
import SystemPackage

// MARK: - Shared Types

/// Conversation state threaded through the agent loop: prior history plus everything
/// committed during this turn.
struct AgentContext: Sendable {
  var messages: [Components.Schemas.ChatMessage]
}

/// The provider-neutral configuration the shared agent loop relies on. Provider configs
/// (`AgentLoopConfig`, `CodexAgentLoopConfig`) already carry these fields, so conformance
/// is a one-line extension and the loop stays agnostic of HTTP specifics.
protocol AgentLoopConfigFields: Sendable {
  var toolExecutor: any ToolExecutor { get }
  var chatTools: [Components.Schemas.ChatTool] { get }
  var maxToolRounds: Int { get }
  var workingDirectory: FilePath { get }
  var hooks: AgentLoopHooks { get }
  var contextWindow: Int { get }
}

/// The result of a single provider round trip: the assistant message to commit and how
/// the round ended.
struct RoundResult: Sendable {
  let assistantMessage: Components.Schemas.ChatMessage
  let kind: RoundOutcome
}

enum RoundOutcome: Sendable, Equatable {
  case completed
  case incomplete(reason: String?)
  case toolCalls([ToolInvocation])
}

// MARK: - Agent Loop Core

/// Runs the provider-neutral agent orchestration: prompt injection, per-round request
/// budget enforcement, abort checks, context-overflow recovery, tool dispatch with
/// hooks, and attachment injection. Providers supply only `runRound`, which performs a
/// single HTTP round trip and stream decode.
///
/// `logTag` is appended to every log event name (e.g. ".codex") so provider logs remain
/// distinguishable while the orchestration stays identical.
func runAgentLoopCore(
  promptMessages: [Components.Schemas.ChatMessage],
  context: AgentContext,
  config: some AgentLoopConfigFields,
  logTag: String,
  emit: @escaping @Sendable (AgentEvent) -> Void,
  logger: Logger,
  abortObserver: some AbortObserver,
  runRound: @escaping @Sendable ([Components.Schemas.ChatMessage], Int) async throws -> RoundResult
) async throws -> (messages: [Components.Schemas.ChatMessage], termination: TurnOutcome) {
  var currentContext = context
  var newMessages: [Components.Schemas.ChatMessage] = []
  var outcome: TurnOutcome = .completed

  emit(.boundary(.agentStart))
  defer { emit(.boundary(.agentEnd(outcome))) }

  for msg in promptMessages {
    emit(.boundary(.messageStart(role: .user, round: 0)))
    currentContext.messages.append(msg)
    newMessages.append(msg)
    emit(.boundary(.messageEnd(role: .user, round: 0)))
  }

  var round = 0
  var attemptedRecovery = false

  while true {
    round += 1
    if abortObserver.isAborted() {
      logger.debug("agent.abort\(logTag)", metadata: ["where": "before-http", "round": "\(round)"])
      outcome = .interrupted
      return (newMessages, outcome)
    }

    emit(.boundary(.turnStart(round: round)))

    do {
      if let reason = try enforceRequestBudget(
        messages: &currentContext.messages,
        newMessages: &newMessages,
        tools: config.chatTools,
        contextWindow: config.contextWindow)
      {
        logger.notice(
          "agent.request.preflight.compacted\(logTag)",
          metadata: ["round": "\(round)", "reason": "\(reason)"])
        emit(.lifecycle(.recovered(reason: reason)))
      }
    } catch {
      let description = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
      logger.warning(
        "agent.request.preflight.rejected\(logTag)",
        metadata: ["round": "\(round)", "err": "\(description)"])
      emit(.boundary(.turnEnd(round: round, outcome: .error(description))))
      outcome = .error(description)
      return (newMessages, outcome)
    }

    let roundResult: RoundResult
    do {
      roundResult = try await abortObserver.race { [currentContext, round] in
        try await runRound(currentContext.messages, round)
      }
    } catch is AgentTurnInterruptedError {
      logger.notice("agent.abort\(logTag)", metadata: ["where": "mid-stream", "round": "\(round)"])
      emit(.boundary(.turnEnd(round: round, outcome: .interrupted)))
      outcome = .interrupted
      return (newMessages, outcome)
    } catch let scribeError as ScribeError where !attemptedRecovery && isContextLengthError(scribeError) {
      let detail = scribeError.errorDescription ?? String(describing: scribeError)
      guard
        let reason = rollbackContextOverflow(
          messages: &currentContext.messages,
          newMessages: &newMessages,
          providerDetail: detail)
      else {
        outcome = .error(scribeError.errorDescription ?? String(describing: scribeError))
        throw scribeError
      }
      attemptedRecovery = true
      logger.notice("agent.recover\(logTag)", metadata: ["round": "\(round)", "reason": "\(reason)"])
      emit(.lifecycle(.recovered(reason: reason)))
      emit(.boundary(.turnEnd(round: round, outcome: .completed)))
      continue
    } catch let scribeError as ScribeError
      where attemptedRecovery && isContextLengthError(scribeError) && scribeError.isInBandStreamError
    {
      // The provider still reports context overflow after one compaction retry. End the
      // turn gracefully for in-band stream errors; HTTP-level failures keep propagating
      // so callers can inspect the status code.
      let description = scribeError.errorDescription ?? String(describing: scribeError)
      logger.error(
        "agent.loop.error\(logTag)",
        metadata: [
          "round": "\(round)",
          "partial_messages": "\(newMessages.count)",
          "err": "\(description)",
        ])
      emit(.boundary(.turnEnd(round: round, outcome: .error(description))))
      outcome = .error(description)
      return (newMessages, outcome)
    } catch let scribeError as ScribeError {
      // Non-recoverable ScribeErrors (apiHTTPError, etc.) — propagate
      // so callers can inspect the specific error type.
      outcome = .error(scribeError.errorDescription ?? String(describing: scribeError))
      throw scribeError
    } catch {
      let description = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
      logger.error(
        "agent.loop.error\(logTag)",
        metadata: [
          "round": "\(round)",
          "partial_messages": "\(newMessages.count)",
          "err": "\(description)",
        ])
      emit(.boundary(.turnEnd(round: round, outcome: .error(description))))
      outcome = .error(description)
      return (newMessages, outcome)
    }

    var roundBuffer: [Components.Schemas.ChatMessage] = [roundResult.assistantMessage]

    if abortObserver.isAborted() {
      logger.debug("agent.abort\(logTag)", metadata: ["where": "post-stream-pre-tools", "round": "\(round)"])
      emit(.boundary(.turnEnd(round: round, outcome: .interrupted)))
      outcome = .interrupted
      return (newMessages, outcome)
    }

    switch roundResult.kind {
    case .completed:
      emit(.boundary(.turnEnd(round: round, outcome: .completed)))
      commit(&currentContext.messages, &newMessages, roundBuffer)
      outcome = .completed
      return (newMessages, outcome)

    case .incomplete(let reason):
      emit(.boundary(.turnEnd(round: round, outcome: .incomplete(reason: reason))))
      commit(&currentContext.messages, &newMessages, roundBuffer)
      outcome = .incomplete(reason: reason)
      return (newMessages, outcome)

    case .toolCalls(let invocations):
      emit(.boundary(.turnEnd(round: round, outcome: .toolCalls(count: invocations.count))))
      if round >= config.maxToolRounds {
        logger.notice("agent.turn.tool-round-limit\(logTag)", metadata: ["max": "\(config.maxToolRounds)"])
        outcome = .toolRoundLimit(rounds: config.maxToolRounds)
        return (newMessages, outcome)
      }

      logger.info(
        "agent.tool.round\(logTag)",
        metadata: [
          "round": "\(round)", "tool_count": "\(invocations.count)",
          "tools": "\(invocations.map(\.name).joined(separator: ","))",
        ])

      for inv in invocations {
        if abortObserver.isAborted() {
          logger.notice(
            "agent.abort\(logTag)",
            metadata: ["where": "pre-tool", "tool": "\(inv.name)", "round": "\(round)"])
          outcome = .interrupted
          return (newMessages, outcome)
        }

        let beforeDecision = await config.hooks.beforeToolCall(inv)
        let resolvedInv: ToolInvocation
        let preflightResult: ToolResult?
        switch beforeDecision {
        case .proceed(let rewritten):
          resolvedInv = rewritten
          preflightResult = nil
        case .block(let reason):
          resolvedInv = inv
          preflightResult = ToolResult.text(ToolRegistry.jsonError(reason))
        }

        emit(.boundary(.toolExecutionStart(name: resolvedInv.name, arguments: resolvedInv.arguments)))

        let result: ToolResult
        if let preflightResult {
          result = preflightResult
        } else {
          do {
            result = try await config.toolExecutor.execute(
              resolvedInv,
              workingDirectory: config.workingDirectory,
              logger: logger,
              abort: abortObserver)
          } catch is AgentTurnInterruptedError {
            outcome = .interrupted
            return (newMessages, outcome)
          } catch let ScribeError.toolUnknown(name) {
            logger.warning("agent.tool.unknown\(logTag)", metadata: ["tool": "\(name)", "round": "\(round)"])
            result = ToolResult.text(ToolRegistry.jsonError("unknown tool \(name)"))
          } catch {
            logger.warning(
              "agent.tool.executor.error\(logTag)",
              metadata: [
                "tool": "\(resolvedInv.name)", "round": "\(round)",
                "err": "\(String(describing: error).replacingOccurrences(of: "\"", with: "\\\""))",
              ])
            result = ToolResult.text(ToolRegistry.jsonError(String(describing: error)))
          }
        }

        let afterDecision = await config.hooks.afterToolCall(resolvedInv, result)
        let finalResult = afterDecision.result
        emit(.boundary(.toolExecutionEnd(name: resolvedInv.name, output: finalResult.text)))
        emit(.tool(.invocation(name: resolvedInv.name, arguments: resolvedInv.arguments, output: finalResult.text)))
        for warning in finalResult.warnings {
          emit(.tool(.warning(warning)))
        }

        emit(.boundary(.messageStart(role: .tool, round: round)))
        roundBuffer.append(
          Components.Schemas.ChatMessage(
            role: .tool, content: .case1(finalResult.text),
            name: nil, toolCalls: nil, toolCallId: resolvedInv.id))
        emit(.boundary(.messageEnd(role: .tool, round: round)))

        for attachment in finalResult.attachments {
          logger.info(
            "agent.tool.attachment.inject\(logTag)",
            metadata: [
              "round": "\(round)",
              "tool": "\(resolvedInv.name)",
              "mime_type": "\(attachment.mimeType)",
              "base64_chars": "\(attachment.base64.count)",
              "source_path": "\(attachment.sourcePath ?? "nil")",
            ])
          emit(.boundary(.messageStart(role: .user, round: round)))
          roundBuffer.append(toolAttachmentMessage(attachment))
          emit(.boundary(.messageEnd(role: .user, round: round)))
        }

        if afterDecision.terminate {
          commit(&currentContext.messages, &newMessages, roundBuffer)
          outcome = .completed
          return (newMessages, outcome)
        }
      }

      commit(&currentContext.messages, &newMessages, roundBuffer)
    }
  }
}

private func commit(
  _ context: inout [Components.Schemas.ChatMessage],
  _ newMessages: inout [Components.Schemas.ChatMessage],
  _ buffer: [Components.Schemas.ChatMessage]
) {
  context.append(contentsOf: buffer)
  newMessages.append(contentsOf: buffer)
}

// MARK: - Attachments

/// Builds the synthetic user message that carries a tool-produced attachment into the
/// conversation. Shared by every provider so multimodal injection stays identical.
func toolAttachmentMessage(
  _ attachment: ToolAttachment
) -> Components.Schemas.ChatMessage {
  let label = (attachment.sourcePath ?? attachment.filename).map { "\($0):" } ?? "Attached media:"
  return ScribeMessage(
    role: .user,
    contentParts: [
      .text(label),
      .image(url: attachment.dataUri, detail: nil),
    ]
  ).toChatMessage()
}

// MARK: - Context Overflow Recovery

func isContextLengthError(_ error: ScribeError) -> Bool {
  let detail: String
  switch error {
  case .apiHTTPError(let statusCode, let message, _):
    guard statusCode == 400 || statusCode == 413 else { return false }
    detail = message
  case .generic(let message):
    detail = message
  default:
    return false
  }

  let lower = detail.lowercased()
  return lower.contains("context_length_exceeded")
    || lower.contains("input_too_large")
    || lower.contains("context length")
    || lower.contains("context window")
    || lower.contains("prompt is too long")
    || lower.contains("prompt too long")
    || lower.contains("maximum context")
    || lower.contains("request payload exceeds the limit")
}

func rollbackContextOverflow(
  messages: inout [Components.Schemas.ChatMessage],
  newMessages: inout [Components.Schemas.ChatMessage],
  providerDetail: String
) -> String? {
  let newMessageStart = messages.count - newMessages.count
  var toolIndexesToReplace = Set<Int>()
  var attachmentIndexesToRemove = Set<Int>()

  // Tool-generated attachments are inserted immediately after their tool result. Preserve
  // ordinary multimodal user prompts, but discard attachment messages created by tools.
  for index in messages.indices where isImageMessage(messages[index]) {
    guard index > messages.startIndex, messages[index - 1].role == .tool else { continue }
    attachmentIndexesToRemove.insert(index)
    toolIndexesToReplace.insert(index - 1)
  }

  // Old sessions can contain tool output written before the global result ceiling existed.
  // Compact every conspicuously large result so a single retry has the best chance to fit.
  for index in messages.indices where messages[index].role == .tool {
    if messageTextSize(messages[index]) > 32 * 1024 {
      toolIndexesToReplace.insert(index)
    }
  }

  // Providers do not report which input item crossed the limit. If no obvious attachment or
  // oversized output exists, compact the largest tool result rather than retrying unchanged.
  if toolIndexesToReplace.isEmpty,
    let largest = messages.indices.filter({
      messages[$0].role == .tool && !isContextOverflowReplacement(messages[$0])
    }).max(by: {
      messageTextSize(messages[$0]) < messageTextSize(messages[$1])
    })
  {
    toolIndexesToReplace.insert(largest)
  }

  guard !toolIndexesToReplace.isEmpty else { return nil }

  let detail =
    providerDetail.count > 512
    ? String(providerDetail.prefix(512)) + "…"
    : providerDetail
  for index in toolIndexesToReplace {
    let original = messages[index]
    messages[index] = contextOverflowReplacement(original: original, providerDetail: detail)
  }

  for index in attachmentIndexesToRemove.sorted(by: >) {
    messages.remove(at: index)
  }

  // newMessages is the suffix accumulated during this turn. Mirror changes that landed in it
  // so persistence and the retry context remain identical.
  for contextIndex in toolIndexesToReplace where contextIndex >= newMessageStart {
    let newIndex = contextIndex - newMessageStart
    guard newMessages.indices.contains(newIndex) else { continue }
    let original = newMessages[newIndex]
    newMessages[newIndex] = contextOverflowReplacement(
      original: original, providerDetail: detail)
  }
  for contextIndex in attachmentIndexesToRemove.sorted(by: >) where contextIndex >= newMessageStart {
    let newIndex = contextIndex - newMessageStart
    if newMessages.indices.contains(newIndex) { newMessages.remove(at: newIndex) }
  }

  return "model context overflow — compacted \(toolIndexesToReplace.count) tool result(s)"
    + (attachmentIndexesToRemove.isEmpty
      ? "" : " and dropped \(attachmentIndexesToRemove.count) attachment(s)")
}

private func isImageMessage(_ message: Components.Schemas.ChatMessage) -> Bool {
  guard case .case2(let parts) = message.content else { return false }
  return parts.contains { part in
    if case .imageUrl = part { return true }
    return false
  }
}

private func messageTextSize(_ message: Components.Schemas.ChatMessage) -> Int {
  guard case .case1(let text) = message.content else { return 0 }
  return text.utf8.count
}

private func isContextOverflowReplacement(_ message: Components.Schemas.ChatMessage) -> Bool {
  guard case .case1(let text) = message.content else { return false }
  return text.contains("tool output exceeded model context window and was removed")
}

private func contextOverflowReplacement(
  original: Components.Schemas.ChatMessage,
  providerDetail: String
) -> Components.Schemas.ChatMessage {
  let errorJSON = ToolRegistry.jsonError(
    "tool output exceeded model context window and was removed. provider error: \(providerDetail)"
  )
  return Components.Schemas.ChatMessage(
    role: .tool,
    content: .case1(errorJSON),
    name: original.name,
    toolCalls: nil,
    toolCallId: original.toolCallId
  )
}

extension ScribeError {
  /// True for failures reported inside the provider's event stream, which surface as
  /// `.generic`. HTTP-level failures remain `.apiHTTPError` so callers can inspect the
  /// status code.
  fileprivate var isInBandStreamError: Bool {
    if case .generic = self { return true }
    return false
  }
}
