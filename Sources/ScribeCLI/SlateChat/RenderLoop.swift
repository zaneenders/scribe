import ScribeCore


/// Pure-value snapshot of everything needed to build a single render frame.
/// Collected by the host and passed into `RenderLoop.buildFrame`.
struct RenderState {
  var transcriptLines: [TLine]
  var streamingOpenLine: TLine?
  var generation: Int
  var flattenCache: TranscriptLayout.FlattenCache
  var banner: BannerSnapshot?
  var usageHUD: UsageHUDSnapshot?
  var inputBuffer: String
  var modelBusy: Bool
  var queuedTrayMessages: [String]
  var llmWaitAnimationFrame: Int
  var viewport: TranscriptViewport
  var cols: Int
  var rows: Int
}


/// The computed output of `buildFrame`: everything the host needs to paint.
struct RenderOutput {
  /// Flattened (wrapped) transcript lines for the visible area.
  var flattenedTranscript: [TLine]
  /// First visible row index in the flattened transcript (viewport-adjusted).
  var transcriptTailStart: Int
  /// Updated viewport state (scroll position resolved).
  var viewport: TranscriptViewport
  /// Updated flatten cache.
  var flattenCache: TranscriptLayout.FlattenCache
}


/// Pure-function render pipeline: takes immutable state, returns what to render.
///
/// The host collects `RenderState` on `@MainActor`, calls `buildFrame`, then feeds
/// the resulting `RenderOutput` into `SlateChatRenderer.render(into:...)`.
enum RenderLoop {

  /// Build a render frame from state. Pure function — no side effects, no async.
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
      queuedTrayMessages: state.queuedTrayMessages)

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
