import Foundation
import Testing
import SlateCore

@testable import ScribeCLI

// MARK: - RenderLoop frame-level tests

/// Tests that `buildFrame` correctly produces the semantic grid for common
/// frame configurations without requiring Slate or a terminal.
@Suite
struct RenderLoopTests {

    // MARK: - Default state

    /// Returns a minimal `RenderState` suitable as a test baseline.
    private static func defaultState(cols: Int = 80, rows: Int = 24) -> RenderState {
        RenderState(
            inputBuffer: "",
            modelBusy: false,
            queuedTrayText: nil,
            banner: nil,
            usage: nil,
            transcriptLines: [],
            streamingOpenLine: nil,
            transcriptGeneration: 0,
            flattenCache: TranscriptLayout.FlattenCache(),
            llmWaitAnimationFrame: 0,
            viewport: TranscriptViewport(),
            cols: cols,
            rows: rows
        )
    }

    // MARK: - Banner tests

    @Test func frameIncludesBannerWhenPresent() {
        var state = Self.defaultState()
        state.banner = BannerSnapshot(
            baseURL: "http://localhost:8080",
            model: "test-model",
            cwd: "/tmp",
            scribeVersion: "abc123",
            gitBranch: "main",
            sessionId: "test-session"
        )
        let output = buildFrame(state: state, theme: .default)

        // Banner row 0 is LLM line (base URL), row 1 is Model line
        let row1Spans = output.grid[1]
        let row1Text = row1Spans.map(\.text).joined()
        #expect(row1Text.contains("test-model"),
            "Expected Model row to contain model name, got: \(row1Text)")
    }

    @Test func bannerRowHasThreeHeaderRows() {
        var state = Self.defaultState()
        state.banner = BannerSnapshot(
            baseURL: "https://api.example.com",
            model: "gpt-4",
            cwd: "/home/user",
            scribeVersion: "1.0.0",
            gitBranch: nil,
            sessionId: "abc12345"
        )
        let output = buildFrame(state: state, theme: .default)

        // Row 0: LLM line
        let row0 = output.grid[0].map(\.text).joined()
        #expect(row0.contains("LLM:"))
        #expect(row0.contains("api.example.com"))

        // Row 1: Model line
        let row1 = output.grid[1].map(\.text).joined()
        #expect(row1.contains("Model:"))
        #expect(row1.contains("gpt-4"))

        // Row 2: CWD line
        let row2 = output.grid[2].map(\.text).joined()
        #expect(row2.contains("CWD:"))
        #expect(row2.contains("/home/user"))
    }

    @Test func bannerShowsGitBranchWhenPresent() {
        var state = Self.defaultState()
        state.banner = BannerSnapshot(
            baseURL: "https://api.example.com",
            model: "test-model",
            cwd: "/tmp",
            scribeVersion: "abc123",
            gitBranch: "feature/branch",
            sessionId: "test-session"
        )
        let output = buildFrame(state: state, theme: .default)

        let row2 = output.grid[2].map(\.text).joined()
        #expect(row2.contains("@feature/branch"),
            "Expected CWD row to show git branch, got: \(row2)")
    }

    // MARK: - Queued tray tests

    @Test func frameShowsQueuedTrayWhenMessageQueued() {
        var state = Self.defaultState()
        state.modelBusy = true
        state.queuedTrayText = "queued message"
        state.inputBuffer = ""

        let output = buildFrame(state: state, theme: .default)

        // Find the row containing "queued:" by joining row text
        let queuedRow = output.grid.first(where: { row in
            row.map(\.text).joined().contains("queued:")
        })
        #expect(queuedRow != nil, "Expected a row with 'queued:' prefix")

        let trayText = queuedRow?.map(\.text).joined() ?? ""
        #expect(trayText.contains("queued message"),
            "Expected tray to contain the message, got: \(trayText)")
    }

    @Test func noQueuedTrayWhenQueueIsEmpty() {
        var state = Self.defaultState()
        state.modelBusy = true
        state.queuedTrayText = nil

        let output = buildFrame(state: state, theme: .default)

        let hasQueuedRow = output.grid.contains(where: { row in
            row.map(\.text).joined().contains("queued:")
        })
        #expect(!hasQueuedRow, "Expected no queued row when tray is empty")
    }

    // MARK: - Input area tests

    @Test func inputAreaShowsBufferText() {
        var state = Self.defaultState()
        state.inputBuffer = "hello world"

        let output = buildFrame(state: state, theme: .default)

        // Find the input row (contains "you:")
        let inputRow = output.grid.first(where: { row in
            row.map(\.text).joined().contains("you:")
        })
        #expect(inputRow != nil, "Expected an input row with 'you:'")

        let inputText = inputRow?.map(\.text).joined() ?? ""
        #expect(inputText.contains("hello world"),
            "Expected input row to contain buffer text, got: \(inputText)")
    }

    @Test func spinnerShowsWhenModelBusyAndBufferEmpty() {
        var state = Self.defaultState()
        state.modelBusy = true
        state.inputBuffer = ""

        let output = buildFrame(state: state, theme: .default)

        // Should show "scribe:" with spinner, not "you:"
        let scribeRow = output.grid.first(where: { row in
            row.map(\.text).joined().contains("scribe:")
        })
        #expect(scribeRow != nil, "Expected spinner row with 'scribe:' when busy + empty buffer")
    }

    @Test func inputShowsCursorOnLastRow() {
        var state = Self.defaultState()
        state.inputBuffer = "typing"

        let output = buildFrame(state: state, theme: .default)

        // Find rows containing "▏" (cursor)
        let cursorRows = output.grid.filter { row in
            row.contains(where: { $0.text == "▏" })
        }
        #expect(!cursorRows.isEmpty, "Expected at least one cursor glyph")
    }

    // MARK: - Transcript tests

    @Test func transcriptContentAppearsInOutput() {
        var state = Self.defaultState()
        state.transcriptLines = [
            TLine(spans: [
                StyledSpan(fg: .blue, bg: .black, bold: false, text: "you:")
            ]),
            TLine(spans: [
                StyledSpan(fg: .white, bg: .black, bold: false, text: "  hello")
            ]),
        ]

        let output = buildFrame(state: state, theme: .default)

        // Without a banner, transcript starts at row 0
        let allText = output.grid.map { row in row.map(\.text).joined() }.joined(separator: "\n")
        #expect(allText.contains("you:"), "Expected transcript to contain 'you:'")
        #expect(allText.contains("hello"), "Expected transcript to contain 'hello'")
    }

    @Test func emptyTranscriptProducesValidGrid() {
        let state = Self.defaultState()
        let output = buildFrame(state: state, theme: .default)

        // Grid should have the right dimensions
        #expect(output.grid.count == state.rows,
            "Expected \(state.rows) rows, got \(output.grid.count)")
        #expect(output.grid.allSatisfy { $0.count == state.cols },
            "Expected all rows to have \(state.cols) columns")
    }

    // MARK: - Viewport updates

    @Test func viewportFollowingLiveWhenAtTail() {
        var state = Self.defaultState()
        state.transcriptLines = (0..<5).map { i in
            TLine(spans: [StyledSpan(fg: .white, bg: .black, bold: false, text: "line \(i)")])
        }
        // Fresh viewport starts followingLive = true
        #expect(state.viewport.followingLive)

        let output = buildFrame(state: state, theme: .default)

        // With small content, should still follow live
        #expect(output.viewportFollowingLive)
    }

    @Test func outputReflectsUpdatedFlattenCache() {
        var state = Self.defaultState()
        state.transcriptLines = [
            TLine(spans: [StyledSpan(fg: .white, bg: .black, bold: false, text: "hello")])
        ]

        let output = buildFrame(state: state, theme: .default)

        // Cache should have been updated
        #expect(output.updatedFlattenCache.completedLogicalLines == 1,
            "Expected cache to track 1 completed line, got \(output.updatedFlattenCache.completedLogicalLines)")
        #expect(!output.flatTranscript.isEmpty,
            "Expected non-empty flat transcript")
    }

    // MARK: - Grid dimensions

    @Test func gridMatchesTerminalDimensions() {
        let state = Self.defaultState(cols: 120, rows: 40)
        let output = buildFrame(state: state, theme: .default)

        #expect(output.grid.count == 40, "Expected 40 rows")
        #expect(output.grid[0].count == 120, "Expected 120 columns")
    }

    // MARK: - Usage HUD tests

    @Test func usageHUDRendersTokenCountsInTopRight() {
        var state = Self.defaultState(cols: 80, rows: 24)
        state.usage = UsageHUDSnapshot(
            roundPrompt: 1_234, roundCompletion: 567,
            turnPrompt: 5_000, turnCompletion: 3_000, turnTotal: 8_000,
            sessionPrompt: 50_000, sessionCompletion: 40_000, sessionTotal: 90_000
        )

        let output = buildFrame(state: state, theme: .default)

        // Usage HUD occupies up to 3 header rows (rows 0-2 when no banner).
        // Row 0: "in 1,234  ·  out 567"
        let row0 = output.grid[0].map(\.text).joined()
        #expect(row0.contains("in"), "Expected 'in' label in HUD row 0")
        #expect(row0.contains("1,234"), "Expected formatted round prompt tokens")
        #expect(row0.contains("out"), "Expected 'out' label in HUD row 0")
        #expect(row0.contains("567"), "Expected formatted round completion tokens")

        // Row 1: detail row (reasoning/cache) is absent when both are nil/0
        // Row 1 (or 2): "turn Σ 8,000  ·  all Σ 90,000"
        // The sums row may be at row 1 or row 2 depending on detail presence
        let sumsRow = output.grid[1..<3].first { row in
            row.map(\.text).joined().contains("turn Σ")
        }
        #expect(sumsRow != nil, "Expected a row with 'turn Σ'")
        let sumsText = sumsRow!.map(\.text).joined()
        #expect(sumsText.contains("8,000"), "Expected formatted turn total")
        #expect(sumsText.contains("all Σ"), "Expected 'all Σ' label")
        #expect(sumsText.contains("90,000"), "Expected formatted session total")
    }

    @Test func usageHUDShowsRateAndContextPercentWhenAvailable() {
        var state = Self.defaultState(cols: 80, rows: 24)
        state.usage = UsageHUDSnapshot(
            roundPrompt: 500, roundCompletion: 200,
            turnPrompt: 1_000, turnCompletion: 800, turnTotal: 1_800,
            sessionPrompt: 10_000, sessionCompletion: 9_000, sessionTotal: 19_000,
            outputTokensPerSecond: 42.5,
            contextWindowUsedPercent: 85
        )

        let output = buildFrame(state: state, theme: .default)

        // Row 0 should include rate and ctx%
        let row0 = output.grid[0].map(\.text).joined()
        #expect(row0.contains("rate"), "Expected 'rate' label when tps is available")
        #expect(row0.contains("42.5/s"), "Expected formatted tokens-per-second")
        #expect(row0.contains("ctx"), "Expected 'ctx' label when context % is available")
        #expect(row0.contains("85%"), "Expected context window used percentage")
    }

    @Test func usageHUDShowsReasoningAndCacheDetailRow() {
        var state = Self.defaultState(cols: 80, rows: 24)
        state.usage = UsageHUDSnapshot(
            roundPrompt: 100, roundCompletion: 50,
            turnPrompt: 500, turnCompletion: 300, turnTotal: 800,
            sessionPrompt: 5_000, sessionCompletion: 4_000, sessionTotal: 9_000,
            reasoningTokens: 200,
            cachedPromptTokens: 150
        )

        let output = buildFrame(state: state, theme: .default)

        // Row 1 should be the detail row with reasoning and cache
        let row1 = output.grid[1].map(\.text).joined()
        #expect(row1.contains("reasoning"), "Expected 'reasoning' label")
        #expect(row1.contains("200"), "Expected reasoning token count")
        #expect(row1.contains("cache"), "Expected 'cache' label")
        #expect(row1.contains("150"), "Expected cached prompt token count")

        // Row 2 should be the sums row
        let row2 = output.grid[2].map(\.text).joined()
        #expect(row2.contains("turn Σ"), "Expected sums row at row 2")
        #expect(row2.contains("800"), "Expected turn total in sums row")
    }

    @Test func noUsageHUDWhenUsageIsNil() {
        var state = Self.defaultState(cols: 80, rows: 24)
        state.usage = nil

        let output = buildFrame(state: state, theme: .default)

        // No header rows at all — transcript area starts at row 0
        let allText = output.grid.map { $0.map(\.text).joined() }.joined()
        #expect(!allText.contains("in  "), "Expected no usage HUD when usage is nil")
        #expect(!allText.contains("turn Σ"), "Expected no sums row when usage is nil")
    }

    // MARK: - Viewport non-following tests

    @Test func viewportStopsFollowingAfterScrollUp() {
        var state = Self.defaultState(cols: 80, rows: 24)
        // Create enough transcript lines to overflow the content area
        // 24 rows, no banner → headerRows=0, input rows=1 → contentRows=23
        // 30 flat lines → viewport can scroll
        state.transcriptLines = (0..<30).map { i in
            TLine(spans: [StyledSpan(fg: .white, bg: .black, bold: false, text: "line \(i)")])
        }

        // Queue a scroll up (away from tail)
        state.viewport.queueScroll(by: -5)
        #expect(state.viewport.followingLive, "Should still be following live before resolve")

        let output = buildFrame(state: state, theme: .default)

        // After scrolling up 5 lines from the tail of 30 lines with ~23 content rows:
        // maxTailStart = max(0, 30 - 23) = 7
        // Scrolling up 5 from maxTailStart: firstVisibleRow = max(0, 7 - 5) = 2
        #expect(!output.viewportFollowingLive, "Expected viewport to stop following live after scroll up")
        #expect(output.transcriptTailStart < 7, "Expected tailStart to be before the tail after scroll up")
    }

    @Test func viewportResumesFollowingAfterScrollToBottom() {
        var state = Self.defaultState(cols: 80, rows: 24)
        state.transcriptLines = (0..<30).map { i in
            TLine(spans: [StyledSpan(fg: .white, bg: .black, bold: false, text: "line \(i)")])
        }

        // Scroll up, then scroll to bottom
        state.viewport.queueScroll(by: -5)
        state.viewport.queueGoToBottom()

        let output = buildFrame(state: state, theme: .default)

        #expect(output.viewportFollowingLive, "Expected viewport to resume following after GoToBottom")
    }

    // MARK: - Streaming / open line tests

    @Test func streamingOpenLineAppearsInFlatTranscript() {
        var state = Self.defaultState(cols: 80, rows: 24)
        state.transcriptLines = [
            TLine(spans: [StyledSpan(fg: .blue, bg: .black, bold: false, text: "you: hello")]),
        ]
        state.streamingOpenLine = TLine(spans: [
            StyledSpan(fg: .green, bg: .black, bold: false, text: "assistant: streaming response..."),
        ])

        let output = buildFrame(state: state, theme: .default)

        // The flat transcript should include both completed and open lines
        let allFlatText = output.flatTranscript.flatMap { $0.spans.map(\.text) }.joined()
        #expect(allFlatText.contains("streaming response"),
            "Expected streaming open line in flat transcript, got: \(allFlatText)")

        // Grid should also contain the streaming text
        let gridText = output.grid.map { $0.map(\.text).joined() }.joined()
        #expect(gridText.contains("streaming response"),
            "Expected streaming open line content in grid, got: \(gridText)")
    }

    @Test func flattenCacheExcludesStreamingOpenLineFromCompletedCount() {
        var state = Self.defaultState(cols: 80, rows: 24)
        state.transcriptLines = [
            TLine(spans: [StyledSpan(fg: .blue, bg: .black, bold: false, text: "line1")]),
            TLine(spans: [StyledSpan(fg: .blue, bg: .black, bold: false, text: "line2")]),
        ]
        state.streamingOpenLine = TLine(spans: [
            StyledSpan(fg: .green, bg: .black, bold: false, text: "streaming..."),
        ])

        let output = buildFrame(state: state, theme: .default)

        // Cache should track only completed lines, not the open line
        #expect(output.updatedFlattenCache.completedLogicalLines == 2,
            "Expected cache to count 2 completed lines (excluding open), got \(output.updatedFlattenCache.completedLogicalLines)")
    }

    // MARK: - Multi-line input wrapping tests

    @Test func inputBufferWrapsToMultipleVisualLines() {
        // 40 cols → textWidth = 35 (40 - 5 gutter)
        // 36 'a' chars → wraps to 2 visual lines at width 35
        var state = Self.defaultState(cols: 40, rows: 15)
        state.inputBuffer = String(repeating: "a", count: 36)

        let output = buildFrame(state: state, theme: .default)

        // Find all input rows (rows with "you:" prefix or gutter continuation)
        let youRowIdx = output.grid.firstIndex(where: { row in
            row.map(\.text).joined().contains("you:")
        })
        #expect(youRowIdx != nil, "Expected an input row with 'you:' prefix")

        // The row after "you:" should be a continuation row (gutter-indented)
        let continuationIdx = (youRowIdx ?? 0) + 1
        #expect(continuationIdx < output.grid.count, "Expected a continuation row after 'you:' row")
        let continuationText = output.grid[continuationIdx].map(\.text).joined().trimmingCharacters(in: .whitespaces)
        #expect(!continuationText.isEmpty, "Expected continuation row to have input text, got empty")
    }

    @Test func multilineInputShowsCursorOnlyOnLastRow() {
        var state = Self.defaultState(cols: 40, rows: 15)
        // 36 'a' → wraps to 2 rows → cursor only on last row
        state.inputBuffer = String(repeating: "a", count: 36)

        let output = buildFrame(state: state, theme: .default)

        // Find all rows with cursor glyph
        let cursorRows = output.grid.filter { row in
            row.contains(where: { $0.text == "▏" })
        }
        #expect(cursorRows.count == 1, "Expected exactly 1 cursor glyph, got \(cursorRows.count)")
    }

    // MARK: - Long input line truncation tests

    @Test func longInputIsCappedToMaxInputRows() {
        // 40 cols → textWidth = 35, maxInputRows for 15 rows = min(8, max(1, 15-0-1)) = 8
        // 12 newline-separated lines → 12 visual lines → capped to 8
        // Use zero-padded identifiers so "L01" isn't a substring of "L10"/"L11"
        var state = Self.defaultState(cols: 40, rows: 15)
        let lines = (0..<12).map { String(format: "L%02d", $0) }
        state.inputBuffer = lines.joined(separator: "\n")

        let output = buildFrame(state: state, theme: .default)

        // The top input lines should be scrolled off (truncated from top)
        // L00, L01, L02, L03 should NOT appear (12 total, 8 retained → top 4 cut)
        let allInputText = output.grid.map { $0.map(\.text).joined() }.joined()
        #expect(!allInputText.contains("L00"),
            "Expected 'L00' to be truncated (scrolled off top), but found it")
        #expect(!allInputText.contains("L01"),
            "Expected 'L01' to be truncated, but found it")
        #expect(!allInputText.contains("L02"),
            "Expected 'L02' to be truncated, but found it")
        #expect(!allInputText.contains("L03"),
            "Expected 'L03' to be truncated, but found it")

        // The last lines should still be visible
        #expect(allInputText.contains("L11"),
            "Expected 'L11' (last line) to be visible after truncation")
        #expect(allInputText.contains("L04"),
            "Expected 'L04' to be visible (first of the 8 retained lines)")
    }

    @Test func shortInputIsNotTruncated() {
        var state = Self.defaultState(cols: 40, rows: 15)
        // 3 newline-separated lines → 3 visual lines, well under maxInputRows (8)
        state.inputBuffer = "lineA\nlineB\nlineC"

        let output = buildFrame(state: state, theme: .default)

        let allInputText = output.grid.map { $0.map(\.text).joined() }.joined()
        #expect(allInputText.contains("lineA"), "Expected all input lines visible for short input")
        #expect(allInputText.contains("lineB"), "Expected all input lines visible for short input")
        #expect(allInputText.contains("lineC"), "Expected all input lines visible for short input")
    }
}
