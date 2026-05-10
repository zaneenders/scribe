import Foundation
import ScribeCore
import SlateCore

// MARK: - Render State

/// All the state needed to render one frame.  Pure value type.
struct RenderState: Equatable, Sendable {
    var inputBuffer: String
    var modelBusy: Bool
    var queuedTrayText: String?
    var banner: BannerSnapshot?
    var usage: UsageHUDSnapshot?
    var transcriptLines: [TLine]
    var streamingOpenLine: TLine?
    var transcriptGeneration: Int
    var flattenCache: TranscriptLayout.FlattenCache
    var llmWaitAnimationFrame: Int
    var viewport: TranscriptViewport
    var cols: Int
    var rows: Int
}

// MARK: - Render Output

/// The output of one frame render — everything needed to paint the screen.
struct RenderOutput: Equatable, Sendable {
    /// Flattened transcript lines starting at `transcriptTailStart`.
    var flatTranscript: [TLine]
    var transcriptTailStart: Int
    var viewportFollowingLive: Bool
    /// Semantic grid — rows × cols of single-character styled spans.
    var grid: [[StyledSpan]]
    var updatedFlattenCache: TranscriptLayout.FlattenCache
    var updatedViewport: TranscriptViewport
}

// MARK: - Pure frame builder

/// Pure function — no side effects, no Slate dependency.
func buildFrame(
    state: RenderState,
    theme: CLITheme
) -> RenderOutput {
    var viewport = state.viewport

    // 1. Flatten transcript (pure)
    let (cache, flatLines) = TranscriptLayout.FlattenCache.flatten(
        cache: state.flattenCache,
        completed: state.transcriptLines,
        open: state.streamingOpenLine,
        width: state.cols,
        generation: state.transcriptGeneration
    )

    // 2. Calculate content rows (pure)
    let contentRows = SlateChatRenderer.transcriptContentRows(
        cols: state.cols,
        rows: state.rows,
        banner: state.banner,
        usage: state.usage,
        inputLine: state.inputBuffer,
        waitingForLLM: state.modelBusy,
        queuedTrayText: state.queuedTrayText
    )

    // 3. Resolve viewport (pure)
    let tailStart = viewport.resolve(flatCount: flatLines.count, contentRows: contentRows)

    // 4. Build semantic grid (pure — no SlateCell, just StyledSpan arrays)
    let grid = SlateChatRenderer.buildGrid(
        cols: state.cols,
        rows: state.rows,
        flattenedTranscript: flatLines,
        transcriptTailStart: tailStart,
        banner: state.banner,
        usage: state.usage,
        inputLine: state.inputBuffer,
        llmWaitAnimationFrame: state.llmWaitAnimationFrame,
        waitingForLLM: state.modelBusy,
        queuedTrayText: state.queuedTrayText,
        theme: theme
    )

    return RenderOutput(
        flatTranscript: flatLines,
        transcriptTailStart: tailStart,
        viewportFollowingLive: viewport.followingLive,
        grid: grid,
        updatedFlattenCache: cache,
        updatedViewport: viewport
    )
}
