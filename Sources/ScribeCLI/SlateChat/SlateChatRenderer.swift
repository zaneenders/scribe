import Foundation
import ScribeCore
import SlateCore

// MARK: - Grid render

@MainActor
internal enum SlateChatRenderer {
  /// Braille spinner (common in TUIs); one cell, advances while waiting for the first token.
  private static let llmWaitSpinner: [Character] = [
    "⣾", "⣽", "⣻", "⢿", "⡿", "⣟", "⣯", "⣷",
  ]

  private static let inputGutterColumns = 5
  /// Width of `queued: ` prefix; continuation rows under the queued tray indent to align under text.
  private static let queuedTrayGutterColumns = 8
  /// Hard cap on tray rows so a long queued message can't push the transcript off-screen.
  private static let queuedTrayMaxRows = 4

  /// Wrapped tray rows for an optional queued submission, capped by ``queuedTrayMaxRows``.
  /// Returns an empty array when ``queuedTrayText`` is nil/empty.
  private static func queuedTrayVisualLines(
    queuedTrayText: String?,
    textWidth: Int
  ) -> [String] {
    guard let raw = queuedTrayText, !raw.isEmpty, textWidth > 0 else { return [] }
    let normalized = raw.replacingOccurrences(of: "\r\n", with: "\n")
    let lines = TranscriptLayout.inputVisualLines(from: normalized, textWidth: textWidth)
    if lines.count <= queuedTrayMaxRows { return lines }
    var capped = Array(lines.prefix(queuedTrayMaxRows))
    if !capped.isEmpty {
      var last = capped[capped.count - 1]
      if last.count > 1 {
        last = String(last.prefix(max(1, last.count - 1))) + "…"
      } else {
        last = "…"
      }
      capped[capped.count - 1] = last
    }
    return capped
  }

  /// Number of rows to reserve for the queued tray strip (0 when no queued message).
  static func queuedTrayRowCount(
    queuedTrayText: String?,
    cols: Int
  ) -> Int {
    let textWidth = max(0, cols &- queuedTrayGutterColumns)
    let lines = queuedTrayVisualLines(queuedTrayText: queuedTrayText, textWidth: textWidth)
    return lines.count
  }

  /// Rows available for transcript text between the fixed header and the input stack (matches ``makeGrid``).
  static func transcriptContentRows(
    cols: Int,
    rows: Int,
    banner: BannerSnapshot?,
    usage: UsageHUDSnapshot?,
    inputLine: String,
    waitingForLLM: Bool,
    queuedTrayText: String?
  ) -> Int {
    let headerRows: Int = {
      if banner != nil {
        return min(3, max(0, rows &- 1))
      }
      if usage != nil, rows >= 2 {
        return min(3, max(1, rows &- 1))
      }
      return 0
    }()

    let showSpinner = waitingForLLM && inputLine.isEmpty
    let textWidth = max(0, cols &- inputGutterColumns)
    let maxInputRows = min(8, max(1, rows &- headerRows &- 1))
    let inputRowCount: Int
    if showSpinner || textWidth == 0 {
      inputRowCount = 1
    } else {
      var lines = TranscriptLayout.inputVisualLines(from: inputLine, textWidth: textWidth)
      let needsExtraCursorRow =
        lines.last.map { $0.count >= textWidth && textWidth > 0 } ?? false
      if needsExtraCursorRow {
        lines.append("")
      }
      let capped = min(maxInputRows, max(1, lines.count))
      inputRowCount = capped
    }

    let trayRowCount = queuedTrayRowCount(queuedTrayText: queuedTrayText, cols: cols)
    let firstInputRow = rows &- inputRowCount
    let firstTrayRow = max(headerRows, firstInputRow &- trayRowCount)
    return max(0, firstTrayRow &- headerRows)
  }

  static func makeGrid(
    cols: Int,
    rows: Int,
    flattenedTranscript: [TLine],
    transcriptTailStart: Int,
    banner: BannerSnapshot?,
    usage: UsageHUDSnapshot?,
    inputLine: String,
    llmWaitAnimationFrame: Int,
    waitingForLLM: Bool,
    queuedTrayText: String?
  ) -> TerminalCellGrid {
    var grid = TerminalCellGrid(
      cols: cols,
      rows: rows,
      filling: TerminalCell(
        glyph: " ", foreground: ScribePalette.white, background: ScribePalette.black, flags: []))

    let headerRows: Int = {
      if banner != nil {
        return min(3, max(0, rows &- 1))
      }
      if usage != nil, rows >= 2 {
        return min(3, max(1, rows &- 1))
      }
      return 0
    }()

    let contentRows = transcriptContentRows(
      cols: cols, rows: rows, banner: banner, usage: usage,
      inputLine: inputLine, waitingForLLM: waitingForLLM,
      queuedTrayText: queuedTrayText)

    let usageReserve: Int = {
      guard let u = usage else { return 0 }
      let w = usageHUDCharCount(u, maxRows: headerRows)
      return min(cols, w &+ 1)
    }()
    let bannerMaxWithUsage = usageReserve > 0 ? max(0, cols &- usageReserve) : cols

    if headerRows >= 1 {
      if let banner {
        paintBannerKV(
          into: &grid, row: 0, cols: cols, maxWidth: bannerMaxWithUsage, label: "LLM: ",
          value: banner.baseURL)
      }
      if let u = usage {
        paintUsageHUD(into: &grid, cols: cols, usage: u, maxRows: headerRows)
      }
    }

    if headerRows >= 2, let banner {
      paintBannerKV(
        into: &grid, row: 1, cols: cols, maxWidth: bannerMaxWithUsage, label: "Model: ",
        value: banner.model)
    }
    if headerRows >= 3, let banner {
      paintBannerKV(
        into: &grid, row: 2, cols: cols, maxWidth: bannerMaxWithUsage, label: "CWD: ", value: banner.cwd)
    }

    let showSpinner = waitingForLLM && inputLine.isEmpty
    let textWidth = max(0, cols &- inputGutterColumns)
    let maxInputRows = min(8, max(1, rows &- headerRows &- 1))
    let visualLines: [String]
    let inputRowCount: Int
    if showSpinner || textWidth == 0 {
      visualLines = []
      inputRowCount = 1
    } else {
      var lines = TranscriptLayout.inputVisualLines(from: inputLine, textWidth: textWidth)
      let needsExtraCursorRow =
        lines.last.map { $0.count >= textWidth && textWidth > 0 } ?? false
      if needsExtraCursorRow {
        lines.append("")
      }
      let capped = min(maxInputRows, max(1, lines.count))
      inputRowCount = capped
      visualLines =
        lines.count > capped
        ? Array(lines.suffix(capped))
        : lines + Array(repeating: "", count: max(0, capped &- lines.count))
    }

    let firstInputRow = rows &- inputRowCount
    let trayTextWidth = max(0, cols &- queuedTrayGutterColumns)
    let rawTrayLines = queuedTrayVisualLines(
      queuedTrayText: queuedTrayText, textWidth: trayTextWidth)
    // Cap tray rows so an oversized tray on a tiny terminal can't overpaint the input strip.
    let availableTrayRows = max(0, firstInputRow &- headerRows)
    let trayVisualLines = Array(rawTrayLines.prefix(availableTrayRows))
    let trayRowCount = trayVisualLines.count
    let firstTrayRow = max(headerRows, firstInputRow &- trayRowCount)
    let wrapW = cols

    fillInputBackground(
      into: &grid, startRow: firstTrayRow, rowCount: trayRowCount &+ inputRowCount, cols: cols,
      background: ScribePalette.inputAreaBg
    )

    if contentRows > 0 {
      let flat = flattenedTranscript
      let maxTailStart = max(0, flat.count &- contentRows)
      let tailStart = min(max(0, transcriptTailStart), maxTailStart)
      let visibleCount = min(contentRows, flat.count &- tailStart)
      let visible = visibleCount > 0 ? Array(flat[tailStart..<(tailStart &+ visibleCount)]) : []
      let topPad = contentRows &- visible.count
      var y = headerRows &+ topPad
      for line in visible {
        guard y < firstTrayRow else { break }
        blit(line: line, into: &grid, column: 0, row: y, width: wrapW)
        y &+= 1
      }
    }

    if trayRowCount > 0 {
      paintQueuedTrayRows(
        into: &grid,
        startRow: firstTrayRow,
        cols: cols,
        textWidth: trayTextWidth,
        visualLines: trayVisualLines)
    }

    paintInputRows(
      into: &grid,
      startRow: firstInputRow,
      cols: cols,
      textWidth: textWidth,
      visualLines: visualLines,
      rowCount: inputRowCount,
      llmWaitAnimationFrame: llmWaitAnimationFrame,
      showSpinner: showSpinner)

    return grid
  }

  private static func formatUsageInt(_ n: Int) -> String {
    ScribeUsageFormatting.groupingInt(n)
  }

  private static func formatUsageIntOpt(_ n: Int?) -> String {
    guard let n else { return "—" }
    return formatUsageInt(n)
  }

  private static func uSpan(_ fg: TerminalRGB, _ text: String, bold: Bool = false) -> StyledSpan {
    StyledSpan(fg: fg, bg: ScribePalette.black, bold: bold, text: text)
  }

  /// Up to three lines, aligned with the three-row config banner: (1) last request in/out/rate, (2) optional R+cache, (3) turn and session Σ.
  /// When ``maxRows`` is smaller than the full set, the optional R/cache row is dropped first so totals stay visible.
  private static func usageHUDLines(from usage: UsageHUDSnapshot, maxRows: Int) -> [TLine] {
    let sep = "  ·  "

    var row0: [StyledSpan] = [
      uSpan(ScribePalette.usageLabel, "in "),
      uSpan(ScribePalette.usagePrompt, formatUsageIntOpt(usage.roundPrompt)),
      uSpan(ScribePalette.usageMuted, sep),
      uSpan(ScribePalette.usageLabel, "out "),
      uSpan(ScribePalette.usageCompletion, formatUsageIntOpt(usage.roundCompletion)),
    ]
    if let tps = usage.outputTokensPerSecond {
      row0.append(uSpan(ScribePalette.usageMuted, sep))
      row0.append(uSpan(ScribePalette.usageLabel, "rate "))
      row0.append(uSpan(ScribePalette.usageRate, String(format: "%.1f/s", tps)))
    }
    let line0 = TLine(spans: row0)

    let hasR = (usage.reasoningTokens ?? 0) > 0
    let hasCache = (usage.cachedPromptTokens ?? 0) > 0
    let lineDetail: TLine? = {
      guard hasR || hasCache else { return nil }
      var row1: [StyledSpan] = []
      if hasR {
        row1.append(uSpan(ScribePalette.usageLabel, "reasoning "))
        row1.append(uSpan(ScribePalette.usageReasoning, formatUsageInt(usage.reasoningTokens!)))
      }
      if hasR && hasCache {
        row1.append(uSpan(ScribePalette.usageMuted, sep))
      }
      if hasCache {
        row1.append(uSpan(ScribePalette.usageLabel, "cache "))
        row1.append(uSpan(ScribePalette.usageCache, formatUsageInt(usage.cachedPromptTokens!)))
      }
      return TLine(spans: row1)
    }()

    let lineSums = TLine(spans: [
      uSpan(ScribePalette.usageLabel, "turn Σ "),
      uSpan(ScribePalette.usageTurnSum, formatUsageInt(usage.turnTotal), bold: true),
      uSpan(ScribePalette.usageMuted, sep),
      uSpan(ScribePalette.usageLabel, "all Σ "),
      uSpan(ScribePalette.usageSessionSum, formatUsageInt(usage.sessionTotal), bold: true),
    ])

    var full: [TLine] = [line0]
    if let lineDetail {
      full.append(lineDetail)
    }
    full.append(lineSums)

    guard maxRows > 0 else { return [] }
    if full.count <= maxRows { return full }
    if maxRows == 1 { return [line0] }
    // maxRows == 2 and we have 3 logical lines: drop the middle (detail) band.
    if maxRows == 2, full.count == 3 {
      return [line0, lineSums]
    }
    return Array(full.prefix(maxRows))
  }

  private static func usageHUDCharCount(_ usage: UsageHUDSnapshot, maxRows: Int) -> Int {
    let ls = usageHUDLines(from: usage, maxRows: maxRows)
    return ls.map { $0.spans.reduce(0) { $0 + $1.text.count } }.max() ?? 0
  }

  private static func paintBannerKV(
    into grid: inout TerminalCellGrid,
    row: Int,
    cols: Int,
    maxWidth: Int,
    label: String,
    value: String
  ) {
    guard row >= 0, row < grid.rows else { return }
    let dk = ScribePalette.grayDark
    let lt = ScribePalette.grayLight
    let bg = ScribePalette.black
    let cap = min(max(0, maxWidth), cols)
    let maxValueChars = max(0, cap &- label.count)
    var v = value
    if v.count > maxValueChars {
      v = String(v.prefix(max(0, maxValueChars &- 1))) + "…"
    }
    let line = TLine(spans: [
      StyledSpan(fg: dk, bg: bg, bold: false, text: label),
      StyledSpan(fg: lt, bg: bg, bold: false, text: v),
    ])
    blit(line: line, into: &grid, column: 0, row: row, width: cap)
  }

  private static func paintUsageHUD(
    into grid: inout TerminalCellGrid,
    cols: Int,
    usage: UsageHUDSnapshot?,
    maxRows: Int
  ) {
    guard let usage, maxRows > 0 else { return }
    let lines = usageHUDLines(from: usage, maxRows: maxRows)
    for (row, line) in lines.enumerated() {
      guard row >= 0, row < grid.rows else { break }
      let w = line.spans.reduce(0) { $0 + $1.text.count }
      let startCol = max(0, cols &- w)
      blit(line: line, into: &grid, column: startCol, row: row, width: cols &- startCol)
    }
  }

  private static func fillInputBackground(
    into grid: inout TerminalCellGrid,
    startRow: Int,
    rowCount: Int,
    cols: Int,
    background: TerminalRGB
  ) {
    guard rowCount > 0 else { return }
    let endRow = min(grid.rows, startRow &+ rowCount)
    var r = max(0, startRow)
    while r < endRow {
      for c in 0..<min(cols, grid.cols) {
        grid[column: c, row: r] = TerminalCell(
          glyph: " ", foreground: ScribePalette.white, background: background, flags: [])
      }
      r &+= 1
    }
  }

  /// Paints the input stack: first row `you: `, continuation rows gutter-indented; caret on the last row.
  private static func paintInputRows(
    into grid: inout TerminalCellGrid,
    startRow: Int,
    cols: Int,
    textWidth: Int,
    visualLines: [String],
    rowCount: Int,
    llmWaitAnimationFrame: Int,
    showSpinner: Bool
  ) {
    let bg = ScribePalette.inputAreaBg
    let gutter = String(repeating: " ", count: min(inputGutterColumns, cols))
    var lineIdx = 0
    while lineIdx < rowCount {
      let row = startRow &+ lineIdx
      guard row >= 0, row < grid.rows else { break }
      var col = 0
      func paint(
        _ text: String,
        foreground: TerminalRGB,
        flags: TerminalCellFlags = []
      ) {
        for ch in text {
          guard col < cols else { return }
          grid[column: col, row: row] = TerminalCell(
            glyph: ch, foreground: foreground, background: bg, flags: flags)
          col += 1
        }
      }

      let onLastInputRow = lineIdx == rowCount &- 1

      if showSpinner, onLastInputRow {
        paint("scribe: ", foreground: ScribePalette.purple)
        let frames = llmWaitSpinner
        let ch = frames[llmWaitAnimationFrame % frames.count]
        paint(String(ch), foreground: ScribePalette.thinking)
        paint("▏", foreground: ScribePalette.white)
      } else if lineIdx == 0 {
        paint("you: ", foreground: ScribePalette.orange)
        if lineIdx < visualLines.count, textWidth > 0 {
          paint(String(visualLines[lineIdx].prefix(textWidth)), foreground: ScribePalette.white)
        }
        if onLastInputRow {
          paint("▏", foreground: ScribePalette.white)
        }
      } else {
        paint(gutter, foreground: ScribePalette.grayDim)
        if lineIdx < visualLines.count, textWidth > 0 {
          paint(String(visualLines[lineIdx].prefix(textWidth)), foreground: ScribePalette.white)
        }
        if onLastInputRow {
          paint("▏", foreground: ScribePalette.white)
        }
      }

      while col < cols {
        grid[column: col, row: row] = TerminalCell(
          glyph: " ", foreground: ScribePalette.white, background: bg, flags: [])
        col += 1
      }
      lineIdx &+= 1
    }
  }

  /// Paints the queued-tray strip that sits between the transcript and the input area:
  /// first row prefixed with `queued: ` (orange) plus the message in dimmed white;
  /// continuation rows align under the message with an 8-space gutter.
  private static func paintQueuedTrayRows(
    into grid: inout TerminalCellGrid,
    startRow: Int,
    cols: Int,
    textWidth: Int,
    visualLines: [String]
  ) {
    guard !visualLines.isEmpty else { return }
    let bg = ScribePalette.inputAreaBg
    let gutterText = String(repeating: " ", count: min(queuedTrayGutterColumns, cols))
    var lineIdx = 0
    while lineIdx < visualLines.count {
      let row = startRow &+ lineIdx
      guard row >= 0, row < grid.rows else { break }
      var col = 0
      func paint(
        _ text: String,
        foreground: TerminalRGB,
        flags: TerminalCellFlags = []
      ) {
        for ch in text {
          guard col < cols else { return }
          grid[column: col, row: row] = TerminalCell(
            glyph: ch, foreground: foreground, background: bg, flags: flags)
          col += 1
        }
      }

      if lineIdx == 0 {
        paint("queued: ", foreground: ScribePalette.orange)
      } else {
        paint(gutterText, foreground: ScribePalette.grayDim)
      }
      if textWidth > 0 {
        paint(String(visualLines[lineIdx].prefix(textWidth)), foreground: ScribePalette.grayLight)
      }

      while col < cols {
        grid[column: col, row: row] = TerminalCell(
          glyph: " ", foreground: ScribePalette.white, background: bg, flags: [])
        col += 1
      }
      lineIdx &+= 1
    }
  }

  private static func blit(line: TLine, into grid: inout TerminalCellGrid, column: Int, row: Int, width: Int) {
    guard row >= 0, row < grid.rows else { return }
    var x = column
    for span in line.spans {
      let flags: TerminalCellFlags = span.bold ? .bold : []
      for ch in span.text {
        guard x < column &+ width, x < grid.cols else { return }
        grid[column: x, row: row] = TerminalCell(
          glyph: ch, foreground: span.fg, background: span.bg, flags: flags)
        x &+= 1
      }
    }
  }
}
