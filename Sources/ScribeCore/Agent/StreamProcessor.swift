import Foundation
import Logging
import OpenAPIRuntime
import ScribeLLM

struct StreamProcessor<AO: AbortObserver> {
  private let onEvent: (AgentEvent) -> Void
  private let logger: Logger
  private let abortObserver: AO
  private let clock = ContinuousClock()

  private(set) var lastUsage: Components.Schemas.CompletionUsage?
  private(set) var streamStarted = false
  private(set) var streamSection: AssistantStreamSection?
  private(set) var firstStreamContentAt: ContinuousClock.Instant?
  private(set) var decodedChunkCount = 0
  private(set) var skippedChunkCount = 0
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
    turn: inout StreamedAssistantTurn
  ) async throws {
    let sseStream = httpBody.asDecodedServerSentEvents(
      while: { $0 != HTTPBody.ByteChunk("[DONE]".utf8) }
    )
    let jsonDecoder = JSONDecoder()

    var loggedFirstChunk = false
    let streamProgressEvery = 200

    do {
      for try await sse in sseStream {
        if abortObserver.isAborted() {
          logger.notice(
            "agent.stream.abort",
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
        if raw == "[DONE]" { break }

        let chunk: Components.Schemas.ChatCompletionChunk
        do {
          chunk = try jsonDecoder.decode(
            Components.Schemas.ChatCompletionChunk.self,
            from: Data(raw.utf8)
          )
        } catch {
          skippedChunkCount += 1
          logger.warning(
            "agent.stream.unreadable-chunk",
            metadata: [
              "chunk_index": "\(decodedChunkCount + 1)",
              "err": "\(error.localizedDescription)",
              "raw_prefix": "\(raw.prefix(120).replacingOccurrences(of: "\"", with: "\\\""))",
            ])
          continue
        }
        decodedChunkCount += 1

        turn.apply(chunk: chunk)

        if let u = chunk.usage {
          lastUsage = u
        }
        for choice in chunk.choices ?? [] {
          guard let delta = choice.delta else { continue }

          for r in [delta.reasoningContent, delta.reasoning].compactMap({ $0 }).filter({ !$0.isEmpty }) {
            if firstStreamContentAt == nil { firstStreamContentAt = clock.now }
            streamStarted = true
            if case .some(.reasoning) = streamSection {

            } else {
              onEvent(.output(.sectionStarted(.reasoning, previous: streamSection)))
              streamSection = .reasoning
            }
            onEvent(.output(.text(.reasoning, r)))
          }

          if let t = delta.content, !t.isEmpty {
            if firstStreamContentAt == nil { firstStreamContentAt = clock.now }
            streamStarted = true
            if case .some(.answer) = streamSection {

            } else {
              onEvent(.output(.sectionStarted(.answer, previous: streamSection)))
              streamSection = .answer
            }
            onEvent(.output(.text(.answer, t)))
          }
        }

        if !loggedFirstChunk {
          loggedFirstChunk = true
          logger.debug(
            "agent.stream.first-chunk",
            metadata: [
              "ttfb_ms": "\((clock.now - httpStart) / .milliseconds(1))"
            ])
        } else if decodedChunkCount % streamProgressEvery == 0 {
          let elapsedMs = Int((clock.now - streamWallStart) / .milliseconds(1))
          let chunksPerSec = Double(decodedChunkCount) / (Double(elapsedMs) / 1000.0)
          logger.trace(
            "agent.stream.progress",
            metadata: [
              "chunks": "\(decodedChunkCount)",
              "elapsed_ms": "\(elapsedMs)",
              "chunks_per_s": "\(String(format: "%.1f", chunksPerSec))",
            ])
        }
      }
    } catch is AgentTurnInterruptedError {
      throw AgentTurnInterruptedError()
    } catch {

      if abortObserver.isAborted() {
        logger.notice(
          "agent.stream.abort",
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
        "agent.stream.error",
        metadata: [
          "chunks": "\(decodedChunkCount)",
          "had_visible_tokens": "\(streamStarted)",
          "err": "\(String(describing: error))",
        ])
      throw error
    }

    if streamStarted {
      onEvent(.output(.finalized))
    } else if turn.text.isEmpty, turn.resolvedToolCalls().isEmpty {
      logger.notice(
        "agent.stream.empty",
        metadata: ["chunks": "\(decodedChunkCount)"])
      onEvent(.output(.empty))
    }
  }
}
