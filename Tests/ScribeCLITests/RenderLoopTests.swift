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
}
