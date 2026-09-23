import Foundation
import Logging
import OpenAPIRuntime
import ScribeLLM
import Synchronization
import SystemPackage

struct AgentContext: Sendable {
  var messages: [Components.Schemas.ChatMessage]
}

protocol AgentLoopConfigFields: Sendable {
  var toolExecutor: any ToolExecutor { get }
  var chatTools: [Components.Schemas.ChatTool] { get }
  var maxToolRounds: Int { get }
  var workingDirectory: FilePath { get }
  var hooks: AgentLoopHooks { get }
  var contextWindow: Int { get }
  var retryPolicy: RetryPolicy { get }
}

struct RoundResult: Sendable {
  let assistantMessage: Components.Schemas.ChatMessage
  let kind: RoundOutcome
}

enum RoundOutcome: Sendable, Equatable {
  case completed
  case incomplete(reason: String?)
  case toolCalls([ToolInvocation])
}

func runAgentLoopCore(
  promptMessages: [Components.Schemas.ChatMessage],
  context: AgentContext,
  config: some AgentLoopConfigFields,
  logTag: String,
  emit: @escaping @Sendable (AgentEvent) -> Void,
  logger: Logger,
  abortObserver: some AbortObserver,
  runRound:
    @escaping @Sendable (
      [Components.Schemas.ChatMessage], Int, @escaping @Sendable (AgentEvent) -> Void
    ) async throws -> RoundResult
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
      roundResult = try await runRoundWithRetry(
        policy: config.retryPolicy,
        logger: logger,
        logTag: logTag,
        round: round,
        emit: emit,
        abortObserver: abortObserver
      ) { [currentContext, round] attemptEmit in
        try await abortObserver.race {
          try await runRound(currentContext.messages, round, attemptEmit)
        }
      }
    } catch is AgentTurnInterruptedError {
      logger.notice("agent.abort\(logTag)", metadata: ["where": "mid-stream", "round": "\(round)"])
      emit(.boundary(.turnEnd(round: round, outcome: .interrupted)))
      outcome = .interrupted
      return (newMessages, outcome)
    } catch let scribeError as ScribeError
      where !attemptedRecovery && isImageInputUnsupportedError(scribeError)
    {
      let detail = scribeError.errorDescription ?? String(describing: scribeError)
      guard
        let reason = rollbackUnsupportedImageInput(
          messages: &currentContext.messages,
          newMessages: &newMessages,
          providerDetail: detail)
      else {
        outcome = .error(detail)
        throw scribeError
      }
      attemptedRecovery = true
      logger.notice("agent.recover\(logTag)", metadata: ["round": "\(round)", "reason": "\(reason)"])
      emit(.lifecycle(.recovered(reason: reason)))
      emit(.boundary(.turnEnd(round: round, outcome: .completed)))
      continue
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

      var pendingAttachments: [(attachment: ToolAttachment, toolName: String)] = []

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
          logger.warning(
            "agent.tool.blocked\(logTag)",
            metadata: ["tool": "\(inv.name)", "round": "\(round)", "reason": "\(reason.logSafe())"])
          preflightResult = ToolRegistry.failureResult(
            tool: inv.name, code: "blocked", description: reason)
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
            result = ToolRegistry.failureResult(
              tool: name, code: "unknown_tool", description: "Unknown tool; no registered tool has this name")
          } catch {
            let description =
              (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            logger.warning(
              "agent.tool.executor.error\(logTag)",
              metadata: [
                "tool": "\(resolvedInv.name)", "round": "\(round)",
                "err": "\(description.logSafe())",
              ])
            result = ToolRegistry.failureResult(
              tool: resolvedInv.name, code: "executor_failed", description: description)
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

        pendingAttachments.append(
          contentsOf: finalResult.attachments.map { (attachment: $0, toolName: resolvedInv.name) })

        if afterDecision.terminate {
          commit(&currentContext.messages, &newMessages, roundBuffer)
          outcome = .completed
          return (newMessages, outcome)
        }
      }

      for pending in pendingAttachments {
        let attachment = pending.attachment
        logger.info(
          "agent.tool.attachment.inject\(logTag)",
          metadata: [
            "round": "\(round)",
            "tool": "\(pending.toolName)",
            "mime_type": "\(attachment.mimeType)",
            "base64_chars": "\(attachment.base64.count)",
            "source_path": "\(attachment.sourcePath ?? "nil")",
          ])
        emit(.boundary(.messageStart(role: .user, round: round)))
        roundBuffer.append(toolAttachmentMessage(attachment))
        emit(.boundary(.messageEnd(role: .user, round: round)))
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

private func runRoundWithRetry(
  policy: RetryPolicy,
  logger: Logger,
  logTag: String,
  round: Int,
  emit: @escaping @Sendable (AgentEvent) -> Void,
  abortObserver: some AbortObserver,
  operation: @escaping @Sendable (@escaping @Sendable (AgentEvent) -> Void) async throws -> RoundResult
) async throws -> RoundResult {
  var retryAttempt = 0
  while true {
    let streamConsumed = Mutex(false)
    let attemptEmit: @Sendable (AgentEvent) -> Void = { event in
      if event.makesStreamOutputVisible {
        streamConsumed.withLock { $0 = true }
      }
      emit(event)
    }
    do {
      return try await operation(attemptEmit)
    } catch {
      guard retryAttempt < policy.maxRetries,
        policy.isRetryable(error),
        !streamConsumed.withLock({ $0 })
      else { throw error }
      retryAttempt += 1
      let backoff = policy.delay(forRetryAttempt: retryAttempt)
      let reason = retryReasonSummary(error)
      logger.notice(
        "agent.retry\(logTag)",
        metadata: [
          "round": "\(round)",
          "attempt": "\(retryAttempt)",
          "max_retries": "\(policy.maxRetries)",
          "backoff": "\(backoff)",
          "err": "\(reason)",
        ])
      emit(.lifecycle(.retrying(attempt: retryAttempt, maxRetries: policy.maxRetries, delay: backoff, reason: reason)))
      do {
        try await abortObserver.race { try await Task.sleep(for: backoff) }
      } catch is AgentTurnInterruptedError {
        throw AgentTurnInterruptedError()
      } catch {
      }
    }
  }
}

private func retryReasonSummary(_ error: any Error) -> String {
  var current = error
  while let clientError = current as? ClientError {
    current = clientError.underlyingError
  }
  let description: String
  switch current {
  case let urlError as URLError:
    description = urlError.localizedDescription
  default:
    description = (current as? LocalizedError)?.errorDescription ?? String(describing: current)
  }
  guard description.count > 200 else { return description }
  return String(description.prefix(200)) + "…"
}

extension AgentEvent {
  fileprivate var makesStreamOutputVisible: Bool {
    switch self {
    case .output, .lifecycle(.usage):
      return true
    case .tool, .lifecycle, .boundary:
      return false
    }
  }
}

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

func isImageInputUnsupportedError(_ error: ScribeError) -> Bool {
  let detail: String
  switch error {
  case .apiHTTPError(let statusCode, let message, _):
    guard statusCode == 400 || statusCode == 422 else { return false }
    detail = message
  case .responsesHTTPError(let statusCode, let message):
    guard statusCode == 400 || statusCode == 422 else { return false }
    detail = message
  case .generic(let message), .providerStreamError(let message, _, _):
    detail = message
  default:
    return false
  }

  let lower = detail.lowercased()
  let rejectsImagePart =
    lower.contains("unknown variant `image_url`")
    || lower.contains("unknown variant \"image_url\"")
    || lower.contains("unsupported content type") && lower.contains("image_url")
    || lower.contains("image_url") && lower.contains("expected `text`")
    || lower.contains("image_url") && lower.contains("expected \"text\"")
  return rejectsImagePart
}

func rollbackUnsupportedImageInput(
  messages: inout [Components.Schemas.ChatMessage],
  newMessages: inout [Components.Schemas.ChatMessage],
  providerDetail: String
) -> String? {
  let newMessageStart = messages.count - newMessages.count
  let imageIndexes = messages.indices.filter { isImageMessage(messages[$0]) }
  guard !imageIndexes.isEmpty else { return nil }

  let detail =
    providerDetail.count > 512
    ? String(providerDetail.prefix(512)) + "…"
    : providerDetail
  for index in imageIndexes {
    let replacement = unsupportedImageReplacement(original: messages[index], providerDetail: detail)
    messages[index] = replacement
    if index >= newMessageStart {
      let newIndex = index - newMessageStart
      if newMessages.indices.contains(newIndex) { newMessages[newIndex] = replacement }
    }
  }

  return "provider rejected image input — replaced \(imageIndexes.count) attachment(s) with text"
}

private func unsupportedImageReplacement(
  original: Components.Schemas.ChatMessage,
  providerDetail: String
) -> Components.Schemas.ChatMessage {
  let labels: [String]
  if case .case2(let parts) = original.content {
    labels = parts.compactMap { part in
      guard case .text(let textPart) = part else { return nil }
      let text = textPart.text.trimmingCharacters(in: .whitespacesAndNewlines)
      return text.isEmpty ? nil : text
    }
  } else {
    labels = []
  }
  let label = labels.joined(separator: "\n")
  let prefix = label.isEmpty ? "An image attachment" : label
  let text =
    "\(prefix) could not be shown because this provider does not support image input. "
    + "Do not infer or claim to have inspected the image. Tell the user that this model cannot read "
    + "images and ask them to provide the relevant content as text, run OCR/image conversion, or "
    + "switch to a vision-capable model. Provider response: \(providerDetail)"
  return Components.Schemas.ChatMessage(role: original.role, content: .case1(text))
}

func isContextLengthError(_ error: ScribeError) -> Bool {
  let detail: String
  switch error {
  case .apiHTTPError(let statusCode, let message, _):
    guard statusCode == 400 || statusCode == 413 else { return false }
    detail = message
  case .responsesHTTPError(let statusCode, let message):
    guard statusCode == 400 || statusCode == 413 else { return false }
    detail = message
  case .generic(let message), .providerStreamError(let message, _, _):
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

  for index in messages.indices where isImageMessage(messages[index]) {
    guard index > messages.startIndex, messages[index - 1].role == .tool else { continue }
    attachmentIndexesToRemove.insert(index)
    toolIndexesToReplace.insert(index - 1)
  }

  for index in messages.indices where messages[index].role == .tool {
    if messageTextSize(messages[index]) > 32 * 1024 {
      toolIndexesToReplace.insert(index)
    }
  }

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
  fileprivate var isInBandStreamError: Bool {
    switch self {
    case .generic, .providerStreamError:
      return true
    default:
      return false
    }
  }
}
