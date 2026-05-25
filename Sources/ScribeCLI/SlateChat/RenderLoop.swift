import ScribeCore

struct RenderState {
  var transcriptLines: [TLine]
  var streamingOpenLine: TLine?
  var generation: Int
  var flattenCache: TranscriptLayout.FlattenCache
  var banner: BannerSnapshot?
  var usageHUD: UsageHUDSnapshot?
  var inputBuffer: String
  var modelBusy: Bool
  var queuedTraySnapshot: QueuedTraySnapshot
  var llmWaitAnimationFrame: Int
  var viewport: TranscriptViewport
  var cols: Int
  var rows: Int
}

struct RenderOutput {

  var flattenedTranscript: [TLine]

  var transcriptTailStart: Int

  var viewport: TranscriptViewport

  var flattenCache: TranscriptLayout.FlattenCache
}

enum RenderLoop {

  @MainActor
  static func buildFrame(state: inout RenderState) -> RenderOutput {
    let cols = state.cols
    let rows = state.rows

    let flatTranscript = TranscriptLayout.FlattenCache.flatten(
      cache: &state.flattenCache,
      completed: state.transcriptLines,
      open: state.streamingOpenLine,
      width: cols,
      generation: state.generation)

    let contentRows = SlateChatRenderer.transcriptContentRows(
      cols: cols,
      rows: rows,
      banner: state.banner,
      usage: state.usageHUD,
      inputLine: state.inputBuffer,
      waitingForLLM: state.modelBusy,
      queuedTraySnapshot: state.queuedTraySnapshot)

    _ = state.viewport.resolve(flatCount: flatTranscript.count, contentRows: contentRows)
    let tailStart = state.viewport.firstVisibleRow

    return RenderOutput(
      flattenedTranscript: flatTranscript,
      transcriptTailStart: tailStart,
      viewport: state.viewport,
      flattenCache: state.flattenCache
    )
  }
}
