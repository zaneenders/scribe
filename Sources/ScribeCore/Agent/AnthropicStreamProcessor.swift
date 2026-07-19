import Foundation
import Logging
import OpenAPIRuntime
import ScribeLLM
import ScribeLLMAnthropic

/// Parses the Anthropic Messages SSE stream into AgentEvent values.
struct AnthropicStreamProcessor<AO: AbortObserver> {
  fileprivate typealias Components = ScribeLLMAnthropic.Components

  private let onEvent: (AgentEvent) -> Void
  private let logger: Logger
  private let abortObserver: AO
  private let clock = ContinuousClock()

  private(set) var lastUsage: ScribeLLMAnthropic.Components.Schemas.Usage?
  private(set) var streamStarted = false
  private(set) var streamSection: AssistantStreamSection?
  private(set) var firstStreamContentAt: ContinuousClock.Instant?
  private(set) var decodedChunkCount = 0
  private(set) var skippedChunkCount = 0
  let streamWallStart: ContinuousClock.Instant

  private(set) var messageId: String?
  private(set) var responseModel: String?

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
    turn: inout AnthropicAssistantTurn
  ) async throws {
    let sseStream = httpBody.asDecodedServerSentEvents(
      while: { _ in true }
    )
    let jsonDecoder = JSONDecoder()

    var loggedFirstChunk = false
    let streamProgressEvery = 200

    do {
      for try await sse in sseStream {
        if abortObserver.isAborted() {
          logger.notice(
            "agent.stream.abort.anthropic",
            metadata: [
              "where": "mid-stream",
              "chunks": "\(decodedChunkCount)",
              "had_visible_tokens": "\(streamStarted)",
            ])
          if streamStarted {
            onEvent(.output(.finalized))
          }
          throw AgentTurnInterruptedError()
        }

        guard let raw = sse.data?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty
        else { continue }

        let eventType = sse.event ?? extractEventType(from: raw)

        guard let data = raw.data(using: .utf8) else {
          skippedChunkCount += 1
          continue
        }

        decodedChunkCount += 1

        if !loggedFirstChunk {
          loggedFirstChunk = true
          logger.debug(
            "agent.stream.first-chunk-anthropic",
            metadata: ["ttfb_ms": "\((clock.now - httpStart) / .milliseconds(1))"]
          )
        } else if decodedChunkCount % streamProgressEvery == 0 {
          let elapsedMs = Int((clock.now - streamWallStart) / .milliseconds(1))
          let chunksPerSec = Double(decodedChunkCount) / (Double(elapsedMs) / 1000.0)
          logger.trace(
            "agent.stream.progress.anthropic",
            metadata: [
              "chunks": "\(decodedChunkCount)",
              "elapsed_ms": "\(elapsedMs)",
              "chunks_per_s": "\(String(format: "%.1f", chunksPerSec))",
            ])
        }

        switch eventType {
        case "message_start":
          if let event = try? jsonDecoder.decode(Components.Schemas.MessageStartEvent.self, from: data) {
            messageId = event.message.id
            responseModel = event.message.model
            lastUsage = event.message.usage
            for (index, block) in event.message.content.enumerated() {
              turn.applyContentBlockStart(index: index, contentBlock: block)
            }
          }

        case "content_block_start":
          if let event = try? jsonDecoder.decode(Components.Schemas.ContentBlockStartEvent.self, from: data) {
            turn.applyContentBlockStartPayload(index: event.index, payload: event.contentBlock)
          }

        case "content_block_delta":
          if let event = try? jsonDecoder.decode(Components.Schemas.ContentBlockDeltaEvent.self, from: data) {
            switch event.delta {
            case .textDelta(let td):
              markStreamStarted()
              emitAnswerDelta(td.text)
              turn.applyTextDelta(index: event.index, text: td.text)

            case .inputJsonDelta(let jd):
              markStreamStarted()
              turn.applyInputJsonDelta(index: event.index, partialJson: jd.partialJson)
            }
          }

        case "content_block_stop":
          if let event = try? jsonDecoder.decode(Components.Schemas.ContentBlockStopEvent.self, from: data) {
            turn.applyContentBlockStop(index: event.index)
          }

        case "message_delta":
          if let event = try? jsonDecoder.decode(Components.Schemas.MessageDeltaEvent.self, from: data) {
            lastUsage = Components.Schemas.Usage(
              inputTokens: lastUsage?.inputTokens ?? 0,
              cacheCreationInputTokens: lastUsage?.cacheCreationInputTokens,
              cacheReadInputTokens: lastUsage?.cacheReadInputTokens,
              outputTokens: event.usage.outputTokens
            )
          }

        case "message_stop":
          if streamStarted {
            onEvent(.output(.finalized))
          }
          return

        case "ping":
          break

        default:
          break
        }
      }
    } catch is AgentTurnInterruptedError {
      throw AgentTurnInterruptedError()
    } catch {
      if abortObserver.isAborted() {
        logger.notice(
          "agent.stream.abort.anthropic",
          metadata: [
            "where": "mid-stream-cancelled",
            "chunks": "\(decodedChunkCount)",
            "had_visible_tokens": "\(streamStarted)",
            "err": "\(String(describing: error))",
          ])
        if streamStarted {
          onEvent(.output(.finalized))
        }
        throw AgentTurnInterruptedError()
      }
      logger.error(
        "agent.stream.error.anthropic",
        metadata: [
          "chunks": "\(decodedChunkCount)",
          "had_visible_tokens": "\(streamStarted)",
          "err": "\(String(describing: error))",
        ])
      throw error
    }

    if streamStarted {
      onEvent(.output(.finalized))
    } else if turn.resolvedText().isEmpty, turn.resolvedToolCalls().isEmpty {
      logger.notice(
        "agent.stream.empty.anthropic",
        metadata: ["chunks": "\(decodedChunkCount)"])
      onEvent(.output(.empty))
    }
  }

  // MARK: - Helpers

  private func extractEventType(from raw: String) -> String? {
    guard let data = raw.data(using: .utf8),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let type = json["type"] as? String else {
      return nil
    }
    return type
  }

  private mutating func markStreamStarted() {
    if firstStreamContentAt == nil { firstStreamContentAt = clock.now }
    streamStarted = true
  }

  private mutating func emitAnswerDelta(_ text: String) {
    if case .some(.answer) = streamSection {
    } else {
      onEvent(.output(.sectionStarted(.answer, previous: streamSection)))
      streamSection = .answer
    }
    onEvent(.output(.text(.answer, text)))
  }
}
