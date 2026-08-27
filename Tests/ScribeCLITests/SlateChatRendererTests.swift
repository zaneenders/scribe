import SlateCore
import Testing

@testable import ScribeCLI
@testable import ScribeKit

@Suite
struct SlateChatRendererBuildSemanticInputRowsTests {

  @Test func editModeShowsEDITLabelInUserPrefixColor() {
    let theme = CLITheme.default
    let cols = 40
    let rows = 3
    var grid = [[StyledSpan]](
      repeating: [StyledSpan](repeating: StyledSpan(fg: .white, bg: .black, bold: false, text: " "), count: cols),
      count: rows
    )

    SlateChatRenderer.buildSemanticInputRows(
      &grid,
      startRow: 0,
      cols: 40,
      textWidth: 34,
      visualLines: ["hello"],
      rowCount: 1,
      inputMode: .edit,
      llmWaitAnimationFrame: 0,
      waitingForLLM: false,
      theme: theme)

    #expect(grid[0][0].text == "E")
    #expect(grid[0][0].fg == theme.userPrefix)
    #expect(grid[0][1].text == "D")
    #expect(grid[0][2].text == "I")
    #expect(grid[0][3].text == "T")
    #expect(grid[0][4].text == ":")
    #expect(grid[0][5].text == " ")
  }

  @Test func readModeShowsREADLabelInScribePrefixColor() {
    let theme = CLITheme.default
    let cols = 40
    let rows = 3
    var grid = [[StyledSpan]](
      repeating: [StyledSpan](repeating: StyledSpan(fg: .white, bg: .black, bold: false, text: " "), count: cols),
      count: rows
    )

    SlateChatRenderer.buildSemanticInputRows(
      &grid,
      startRow: 0,
      cols: 40,
      textWidth: 34,
      visualLines: ["hello"],
      rowCount: 1,
      inputMode: .read,
      llmWaitAnimationFrame: 0,
      waitingForLLM: false,
      theme: theme)

    #expect(grid[0][0].text == "R")
    #expect(grid[0][0].fg == theme.scribePrefix)
    #expect(grid[0][1].text == "E")
    #expect(grid[0][2].text == "A")
    #expect(grid[0][3].text == "D")
    #expect(grid[0][4].text == ":")
    #expect(grid[0][5].text == " ")
  }

  @Test func cursorAppearsOnLastRow() {
    let theme = CLITheme.default
    let cols = 40
    let rows = 3
    var grid = [[StyledSpan]](
      repeating: [StyledSpan](repeating: StyledSpan(fg: .white, bg: .black, bold: false, text: " "), count: cols),
      count: rows
    )

    SlateChatRenderer.buildSemanticInputRows(
      &grid,
      startRow: 0,
      cols: 40,
      textWidth: 34,
      visualLines: ["hello"],
      rowCount: 1,
      inputMode: .edit,
      llmWaitAnimationFrame: 0,
      waitingForLLM: false,
      theme: theme)

    #expect(grid[0][11].text == "▏")
    #expect(grid[0][11].fg == theme.inputCursor)
  }

  @Test func noCursorOnNonLastRow() {
    let theme = CLITheme.default
    let cols = 40
    let rows = 3
    var grid = [[StyledSpan]](
      repeating: [StyledSpan](repeating: StyledSpan(fg: .white, bg: .black, bold: false, text: " "), count: cols),
      count: rows
    )

    SlateChatRenderer.buildSemanticInputRows(
      &grid,
      startRow: 0,
      cols: 40,
      textWidth: 34,
      visualLines: ["line1", "line2"],
      rowCount: 2,
      inputMode: .edit,
      llmWaitAnimationFrame: 0,
      waitingForLLM: false,
      theme: theme)

    #expect(grid[0][11].text == " ")
  }

  @Test func continuationRowsUseGutter() {
    let theme = CLITheme.default
    let cols = 40
    let rows = 3
    var grid = [[StyledSpan]](
      repeating: [StyledSpan](repeating: StyledSpan(fg: .white, bg: .black, bold: false, text: " "), count: cols),
      count: rows
    )

    SlateChatRenderer.buildSemanticInputRows(
      &grid,
      startRow: 0,
      cols: 40,
      textWidth: 34,
      visualLines: ["line1", "line2"],
      rowCount: 2,
      inputMode: .edit,
      llmWaitAnimationFrame: 0,
      waitingForLLM: false,
      theme: theme)

    #expect(grid[0][0].text == "E")

    #expect(grid[1][0].text == " ")
    #expect(grid[1][0].fg == theme.inputGutter)
    #expect(grid[1][5].text == " ")
    #expect(grid[1][6].text == "l")
  }

  @Test func spinnerShowsWhenWaitingForLLM() {
    let theme = CLITheme.default
    let cols = 40
    let rows = 3
    var grid = [[StyledSpan]](
      repeating: [StyledSpan](repeating: StyledSpan(fg: .white, bg: .black, bold: false, text: " "), count: cols),
      count: rows
    )

    SlateChatRenderer.buildSemanticInputRows(
      &grid,
      startRow: 0,
      cols: 40,
      textWidth: 34,
      visualLines: [],
      rowCount: 1,
      inputMode: .edit,
      llmWaitAnimationFrame: 0,
      waitingForLLM: true,
      theme: theme)

    #expect(grid[0][0].text == "E")
    #expect(grid[0][0].fg == theme.userPrefix)

  }

  @Test func buildSemanticInputRowsClipsToGridBounds() {
    let theme = CLITheme.default
    let cols = 10
    let rows = 2
    var grid = [[StyledSpan]](
      repeating: [StyledSpan](repeating: StyledSpan(fg: .white, bg: .black, bold: false, text: " "), count: cols),
      count: rows
    )

    SlateChatRenderer.buildSemanticInputRows(
      &grid,
      startRow: 5,
      cols: 10,
      textWidth: 4,
      visualLines: ["hello"],
      rowCount: 1,
      inputMode: .edit,
      llmWaitAnimationFrame: 0,
      waitingForLLM: false,
      theme: theme)

    #expect(grid[0][0].text == " ")
  }

  @Test func buildSemanticInputRowsNegativeStartRowIsSafe() {
    let theme = CLITheme.default
    let cols = 10
    let rows = 2
    var grid = [[StyledSpan]](
      repeating: [StyledSpan](repeating: StyledSpan(fg: .white, bg: .black, bold: false, text: " "), count: cols),
      count: rows
    )

    SlateChatRenderer.buildSemanticInputRows(
      &grid,
      startRow: -1,
      cols: 10,
      textWidth: 4,
      visualLines: ["hello"],
      rowCount: 1,
      inputMode: .edit,
      llmWaitAnimationFrame: 0,
      waitingForLLM: false,
      theme: theme)

    #expect(grid[0][0].text == " ")
  }
}

@Suite
struct SlateChatRendererQueuedTrayTests {

  @Test func emptyMessagesReturnsNoVisualLines() {
    let lines = SlateChatRenderer.queuedTrayVisualLines(queuedMessages: [], textWidth: 40)
    #expect(lines.isEmpty)
  }

  @Test func singleMessageWrapsToVisualLines() {
    let lines = SlateChatRenderer.queuedTrayVisualLines(
      queuedMessages: ["abcde\nfghij"], textWidth: 5)
    #expect(lines.count == 2)
    #expect(lines[0].text == "abcde")
    #expect(lines[1].text == "fghij")
  }

  @Test func singleMessageCapsAtMaxTrayRows() {
    let lines = SlateChatRenderer.queuedTrayVisualLines(
      queuedMessages: ["abcdefghijklmnopqrstuvwxyz"], textWidth: 2)
    #expect(lines.count == 4)
    #expect(lines[3].text.hasSuffix("…"))
  }

  @Test func multipleMessagesShowIndexedPreviews() {
    let lines = SlateChatRenderer.queuedTrayVisualLines(
      queuedMessages: ["first task", "second task", "third task"],
      textWidth: 40)
    #expect(lines.count == 3)
    #expect(lines[0].kind == .firstMessage)
    #expect(lines[0].text == "[1/3] first task")
    #expect(lines[1].text == "[2/3] second task")
    #expect(lines[2].text == "[3/3] third task")
  }

  @Test func multipleMessagesOverflowRowWhenTruncated() {
    let messages = (1...6).map { "message \($0)" }
    let lines = SlateChatRenderer.queuedTrayVisualLines(
      queuedMessages: messages, textWidth: 40)
    #expect(lines.count == 4)
    #expect(lines[3].kind == .overflowRemaining(3))
  }

  @Test func zeroTextWidthReturnsEmpty() {
    let lines = SlateChatRenderer.queuedTrayVisualLines(
      queuedMessages: ["hello"], textWidth: 0)
    #expect(lines.isEmpty)
  }

  @Test func emptyMessagesReturnsZeroRows() {
    let count = SlateChatRenderer.queuedTrayRowCount(queuedMessages: [], cols: 80)
    #expect(count == 0)
  }

  @Test func singleMessageReturnsCorrectRowCount() {
    let count = SlateChatRenderer.queuedTrayRowCount(
      queuedMessages: ["hello world"], cols: 80)
    #expect(count == 1)
  }

  @Test func multiLineMessageReturnsCorrectRowCount() {
    let count = SlateChatRenderer.queuedTrayRowCount(
      queuedMessages: ["line1\nline2\nline3"], cols: 80)
    #expect(count == 3)
  }

  @Test func buildSemanticQueuedTrayShowsQueuedPrefix() {
    let theme = CLITheme.default
    let cols = 40
    let rows = 3
    var grid = [[StyledSpan]](
      repeating: [StyledSpan](repeating: StyledSpan(fg: .white, bg: .black, bold: false, text: " "), count: cols),
      count: rows
    )

    let paintLines = SlateChatRenderer.queuedTrayVisualLines(
      queuedMessages: ["hello"], textWidth: 34)
    SlateChatRenderer.buildSemanticQueuedTrayRows(
      &grid,
      startRow: 0,
      cols: 40,
      textWidth: 34,
      visualLines: paintLines,
      theme: theme)

    let prefix = "queued: "
    for (i, ch) in prefix.enumerated() {
      #expect(grid[0][i].text == String(ch))
      #expect(grid[0][i].fg == theme.queuedPrefix)
    }
    #expect(grid[0][prefix.count].text == "h")
    #expect(grid[0][prefix.count].fg == theme.queuedText)
  }

  @Test func buildSemanticQueuedTrayContinuationRowsUseGutter() {
    let theme = CLITheme.default
    let cols = 40
    let rows = 3
    var grid = [[StyledSpan]](
      repeating: [StyledSpan](repeating: StyledSpan(fg: .white, bg: .black, bold: false, text: " "), count: cols),
      count: rows
    )

    let paintLines = SlateChatRenderer.queuedTrayVisualLines(
      queuedMessages: ["line one\nline two"], textWidth: 34)
    SlateChatRenderer.buildSemanticQueuedTrayRows(
      &grid,
      startRow: 0,
      cols: 40,
      textWidth: 34,
      visualLines: paintLines,
      theme: theme)

    #expect(grid[0][0].text == "q")
    #expect(grid[1][0].text == " ")
    #expect(grid[1][0].fg == theme.queuedGutter)
  }

  @Test func buildSemanticQueuedTrayEmptyVisualLinesIsNoop() {
    let theme = CLITheme.default
    let cols = 40
    let rows = 3
    var grid = [[StyledSpan]](
      repeating: [StyledSpan](repeating: StyledSpan(fg: .white, bg: .black, bold: false, text: " "), count: cols),
      count: rows
    )

    SlateChatRenderer.buildSemanticQueuedTrayRows(
      &grid,
      startRow: 0,
      cols: 40,
      textWidth: 34,
      visualLines: [],
      theme: theme)

    #expect(grid[0][0].text == " ")
  }

  @Test func buildSemanticQueuedTrayBackgroundUsesInputAreaBg() {
    let theme = CLITheme.default
    let cols = 40
    let rows = 3
    var grid = [[StyledSpan]](
      repeating: [StyledSpan](repeating: StyledSpan(fg: .white, bg: .black, bold: false, text: " "), count: cols),
      count: rows
    )

    let paintLines = SlateChatRenderer.queuedTrayVisualLines(
      queuedMessages: ["test"], textWidth: 34)
    SlateChatRenderer.buildSemanticQueuedTrayRows(
      &grid,
      startRow: 0,
      cols: 40,
      textWidth: 34,
      visualLines: paintLines,
      theme: theme)

    #expect(grid[0][0].bg == theme.inputAreaBg)
    #expect(grid[0][8].bg == theme.inputAreaBg)
  }

  @Test func dispatchSnapshotShowsSendingAndWaitingRows() {
    let snapshot = QueuedTraySnapshot(
      pending: ["second", "third"],
      activeDispatch: .init(index: 1, text: "first"),
      batchTotal: 3,
      modelBusy: true)
    let lines = SlateChatRenderer.queuedTrayVisualLines(snapshot: snapshot, textWidth: 40)
    #expect(lines.count == 3)
    #expect(lines[0].kind == .sending)
    #expect(lines[0].text == "[1/3] first")
    #expect(lines[1].kind == .waiting)
    #expect(lines[1].text == "[2/3] second")
    #expect(lines[2].text == "[3/3] third")
  }

  @Test func autoDrainSnapshotMarksNextUp() {
    let snapshot = QueuedTraySnapshot(
      pending: ["second", "third"],
      batchTotal: 3,
      modelBusy: true)
    let lines = SlateChatRenderer.queuedTrayVisualLines(snapshot: snapshot, textWidth: 40)
    #expect(lines[0].kind == .nextUp)
    #expect(lines[0].text == "[2/3] second")
    #expect(lines[1].kind == .waiting)
    #expect(lines[1].text == "[3/3] third")
  }

  @Test func transcriptContentRowsAccountsForTrayRows() {
    let withoutTray = SlateChatRenderer.transcriptContentRows(
      cols: 80, rows: 24,
      banner: nil, usage: nil,
      inputLine: "", waitingForLLM: false,
      queuedTraySnapshot: QueuedTraySnapshot())
    let withTray = SlateChatRenderer.transcriptContentRows(
      cols: 80, rows: 24,
      banner: nil, usage: nil,
      inputLine: "", waitingForLLM: false,
      queuedTraySnapshot: QueuedTraySnapshot(pending: ["line1\nline2"]))
    #expect(withTray == withoutTray - 2)
  }
}
