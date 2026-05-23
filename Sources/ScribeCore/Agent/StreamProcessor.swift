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
struct StreamProcessor<AO: AbortObserver> {
  private let onEvent: (AgentEvent) -> Void
  private let logger: Logger
  private let abortObserver: AO
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
            onEvent(.output(.sectionStarted(.reasoning, previous: streamSection)))
            streamSection = .reasoning
          }
          onEvent(.output(.text(.reasoning, r)))
        }

        // Answer text events
        if let t = delta.content, !t.isEmpty {
          if firstStreamContentAt == nil { firstStreamContentAt = clock.now }
          streamStarted = true
          if case .some(.answer) = streamSection {
            // already in answer section
          } else {
            onEvent(.output(.sectionStarted(.answer, previous: streamSection)))
            streamSection = .answer
          }
          onEvent(.output(.text(.answer, t)))
        }
      }

      // --- progress tracking ---
      if !loggedFirstChunk {
        loggedFirstChunk = true
        logger.debug(
          "agent.stream.first-chunk",
          metadata: [
            "ttfb_ms": "\((clock.now - httpStart) / .milliseconds(1))",
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
      // The SSE iterator throws when its parent task is cancelled — which is
      // how the abort race in ``runWithAbortRace`` interrupts a stalled
      // network read. Treat any stream error that coincides with an abort
      // request as an interrupt so the loop unwinds cleanly and the UI
      // finalizes any partial output.
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
      throw error
    }

    // --- end-of-stream events ---
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
