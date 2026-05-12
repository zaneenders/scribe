import Foundation
import Logging
import OpenAPIRuntime
import ScribeLLM

// MARK: - StreamProcessor

/// Processes a streaming SSE response from the LLM: decodes chunks, tracks
/// progress, emits transcript events, and delegates **all** text/reasoning
/// accumulation to `StreamedAssistantTurn.apply(chunk:)`.
///
/// This ensures `turn.apply` is the sole owner of accumulation — the
/// `StreamProcessor` only inspects deltas read-only to decide which events
/// to emit, eliminating the double-processing that previously existed when
/// both `processStreamChunks` and `turn.apply` iterated the same fields.
struct StreamProcessor {
  private let onEvent: (TranscriptEvent) -> Void
  private let logger: Logger
  private let abortNotifier: AbortNotifier
  private let clock = ContinuousClock()

  // MARK: - Result fields (read by caller after `process` completes)

  private(set) var lastUsage: Components.Schemas.CompletionUsage?
  private(set) var streamStarted = false
  private(set) var streamSection: AssistantStreamSection?
  private(set) var firstStreamContentAt: ContinuousClock.Instant?
  private(set) var decodedChunkCount = 0
  private(set) var skippedChunkCount = 0
  let streamWallStart: ContinuousClock.Instant

  init(
    onEvent: @escaping (TranscriptEvent) -> Void,
    logger: Logger,
    abortNotifier: AbortNotifier,
    streamWallStart: ContinuousClock.Instant
  ) {
    self.onEvent = onEvent
    self.logger = logger
    self.abortNotifier = abortNotifier
    self.streamWallStart = streamWallStart
  }

  /// Drives the SSE stream to completion (or abort).  Accumulation is
  /// delegated to `turn.apply(chunk:)`; this method only reads delta
  /// fields to decide which transcript events to fire.
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

    for try await sse in sseStream {
      if abortNotifier.isAborted() {
        logger.notice(
          """
          event=agent.stream.abort \
          where=mid-stream \
          chunks=\(decodedChunkCount) \
          had_visible_tokens=\(streamStarted)
          """
        )
        if streamStarted {
          onEvent(.finalizeAssistantStream)
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
          """
          event=agent.stream.unreadable-chunk \
          chunk_index=\(decodedChunkCount + 1) \
          err="\(error.localizedDescription)" \
          raw_prefix="\(raw.prefix(120).replacingOccurrences(of: "\"", with: "\\\""))"
          """
        )
        onEvent(.skippedUnreadableStreamLine)
        continue
      }
      decodedChunkCount += 1

      // --- accumulation (sole owner) ---
      turn.apply(chunk: chunk)

      // --- read-only delta inspection for event emission ---
      if let u = chunk.usage {
        lastUsage = u
      }
      for choice in chunk.choices ?? [] {
        guard let delta = choice.delta else { continue }

        // Reasoning text events
        for r in [delta.reasoningContent, delta.reasoning].compactMap({ $0 }).filter({ !$0.isEmpty }) {
          if firstStreamContentAt == nil { firstStreamContentAt = clock.now }
          streamStarted = true
          if case .some(.reasoning) = streamSection {
            // already in reasoning section
          } else {
            onEvent(.enterAssistantSection(.reasoning, previous: streamSection))
            streamSection = .reasoning
          }
          onEvent(.appendAssistantText(.reasoning, text: r))
        }

        // Answer text events
        if let t = delta.content, !t.isEmpty {
          if firstStreamContentAt == nil { firstStreamContentAt = clock.now }
          streamStarted = true
          if case .some(.answer) = streamSection {
            // already in answer section
          } else {
            onEvent(.enterAssistantSection(.answer, previous: streamSection))
            streamSection = .answer
          }
          onEvent(.appendAssistantText(.answer, text: t))
        }
      }

      // --- progress tracking ---
      if !loggedFirstChunk {
        loggedFirstChunk = true
        logger.debug(
          """
          event=agent.stream.first-chunk \
          ttfb_ms=\((clock.now - httpStart) / .milliseconds(1))
          """
        )
      } else if decodedChunkCount % streamProgressEvery == 0 {
        let elapsedMs = Int((clock.now - streamWallStart) / .milliseconds(1))
        let chunksPerSec = Double(decodedChunkCount) / (Double(elapsedMs) / 1000.0)
        logger.trace(
          """
          event=agent.stream.progress \
          chunks=\(decodedChunkCount) \
          elapsed=\(elapsedMs) \
          chunks_per_s=\(String(format: "%.1f", chunksPerSec))
          """
        )
      }
    }

    // --- end-of-stream events ---
    if streamStarted {
      onEvent(.finalizeAssistantStream)
    } else if turn.text.isEmpty, turn.resolvedToolCalls().isEmpty {
      logger.notice(
        """
        event=agent.stream.empty \
        chunks=\(decodedChunkCount)
        """
      )
      onEvent(.emptyAssistantTurn)
    }
  }
}
