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
    let fill = TerminalCell(
      glyph: " ", foreground: ScribePalette.white, background: ScribePalette.black, flags: [])
    var grid = TerminalCellGrid(cols: cols, rows: rows, filling: fill)

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
    let availableTrayRows = max(0, firstInputRow &- headerRows)
    let trayVisualLines = Array(rawTrayLines.prefix(availableTrayRows))
    let trayRowCount = trayVisualLines.count
    let firstTrayRow = max(headerRows, firstInputRow &- trayRowCount)

    // Fill input/tray background region in one blit
    let inputBgRowCount = trayRowCount &+ inputRowCount
    if inputBgRowCount > 0 {
      grid.blit(
        column: 0, row: firstTrayRow, width: cols, height: inputBgRowCount,
        repeating: TerminalCell(
          glyph: " ", foreground: ScribePalette.white,
          background: ScribePalette.inputAreaBg, flags: []))
    }

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
        grid.blitSpans(column: 0, row: y, maxWidth: cols, line.toSlateSpans)
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

  private static let hudBG = ScribePalette.black

  private static func hudSpan(_ fg: TerminalRGB, _ text: String, bold: Bool = false) -> TerminalStyledSpan {
    TerminalStyledSpan(text, foreground: fg, background: hudBG, flags: bold ? .bold : [])
  }

  /// Up to three lines of spans for the upper-right HUD.  When `maxRows` is small the
  /// optional R/cache row is dropped first so totals stay visible.
  private static func usageHUDSpans(from usage: UsageHUDSnapshot, maxRows: Int) -> [[TerminalStyledSpan]] {
    let sep = "  ·  "

    var row0: [TerminalStyledSpan] = [
      hudSpan(ScribePalette.usageLabel, "in "),
      hudSpan(ScribePalette.usagePrompt, formatUsageIntOpt(usage.roundPrompt)),
      hudSpan(ScribePalette.usageMuted, sep),
      hudSpan(ScribePalette.usageLabel, "out "),
      hudSpan(ScribePalette.usageCompletion, formatUsageIntOpt(usage.roundCompletion)),
    ]
    if let tps = usage.outputTokensPerSecond {
      row0.append(hudSpan(ScribePalette.usageMuted, sep))
      row0.append(hudSpan(ScribePalette.usageLabel, "rate "))
      row0.append(hudSpan(ScribePalette.usageRate, String(format: "%.1f/s", tps)))
    }
    if let pct = usage.contextWindowUsedPercent {
      row0.append(hudSpan(ScribePalette.usageMuted, sep))
      row0.append(hudSpan(ScribePalette.usageLabel, "ctx "))
      let pctColor: TerminalRGB =
        pct >= 90 ? ScribePalette.red : (pct >= 75 ? ScribePalette.yellow : ScribePalette.usageLabel)
      row0.append(hudSpan(pctColor, "\(pct)%"))
    }

    let hasR = (usage.reasoningTokens ?? 0) > 0
    let hasCache = (usage.cachedPromptTokens ?? 0) > 0
    let lineDetail: [TerminalStyledSpan]? = {
      guard hasR || hasCache else { return nil }
      var row1: [TerminalStyledSpan] = []
      if hasR {
        row1.append(hudSpan(ScribePalette.usageLabel, "reasoning "))
        row1.append(hudSpan(ScribePalette.usageReasoning, formatUsageInt(usage.reasoningTokens!)))
      }
      if hasR && hasCache {
        row1.append(hudSpan(ScribePalette.usageMuted, sep))
      }
      if hasCache {
        row1.append(hudSpan(ScribePalette.usageLabel, "cache "))
        row1.append(hudSpan(ScribePalette.usageCache, formatUsageInt(usage.cachedPromptTokens!)))
      }
      return row1
    }()

    let lineSums: [TerminalStyledSpan] = [
      hudSpan(ScribePalette.usageLabel, "turn Σ "),
      hudSpan(ScribePalette.usageTurnSum, formatUsageInt(usage.turnTotal), bold: true),
      hudSpan(ScribePalette.usageMuted, sep),
      hudSpan(ScribePalette.usageLabel, "all Σ "),
      hudSpan(ScribePalette.usageSessionSum, formatUsageInt(usage.sessionTotal), bold: true),
    ]

    var full: [[TerminalStyledSpan]] = [row0]
    if let lineDetail { full.append(lineDetail) }
    full.append(lineSums)

    guard maxRows > 0 else { return [] }
    if full.count <= maxRows { return full }
    if maxRows == 1 { return [row0] }
    if maxRows == 2, full.count == 3 { return [row0, lineSums] }
    return Array(full.prefix(maxRows))
  }

  private static func usageHUDCharCount(_ usage: UsageHUDSnapshot, maxRows: Int) -> Int {
    usageHUDSpans(from: usage, maxRows: maxRows)
      .map { $0.reduce(0) { $0 + $1.text.count } }.max() ?? 0
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
    let bg = ScribePalette.black
    let cap = min(max(0, maxWidth), cols)
    let maxValueChars = max(0, cap &- label.count)
    var v = value
    if v.count > maxValueChars {
      v = String(v.prefix(max(0, maxValueChars &- 1))) + "…"
    }
    grid.blitSpans(
      column: 0, row: row, maxWidth: cap,
      [
        TerminalStyledSpan(label, foreground: ScribePalette.grayDark, background: bg),
        TerminalStyledSpan(v, foreground: ScribePalette.grayLight, background: bg),
      ])
  }

  private static func paintUsageHUD(
    into grid: inout TerminalCellGrid,
    cols: Int,
    usage: UsageHUDSnapshot?,
    maxRows: Int
  ) {
    guard let usage, maxRows > 0 else { return }
    let lines = usageHUDSpans(from: usage, maxRows: maxRows)
    for (row, spans) in lines.enumerated() {
      guard row >= 0, row < grid.rows else { break }
      let w = spans.reduce(0) { $0 + $1.text.count }
      let startCol = max(0, cols &- w)
      grid.blitSpans(column: startCol, row: row, maxWidth: cols &- startCol, spans)
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
      let onLastInputRow = lineIdx == rowCount &- 1

      var spans: [TerminalStyledSpan] = []
      if showSpinner, onLastInputRow {
        spans.append(TerminalStyledSpan("scribe: ", foreground: ScribePalette.purple, background: bg))
        let frames = llmWaitSpinner
        let ch = frames[llmWaitAnimationFrame % frames.count]
        spans.append(TerminalStyledSpan(String(ch), foreground: ScribePalette.yellowBright, background: bg))
        spans.append(TerminalStyledSpan("▏", foreground: ScribePalette.white, background: bg))
      } else if lineIdx == 0 {
        spans.append(TerminalStyledSpan("you: ", foreground: ScribePalette.orange, background: bg))
        if lineIdx < visualLines.count, textWidth > 0 {
          spans.append(
            TerminalStyledSpan(
              String(visualLines[lineIdx].prefix(textWidth)), foreground: ScribePalette.white, background: bg))
        }
        if onLastInputRow {
          spans.append(TerminalStyledSpan("▏", foreground: ScribePalette.white, background: bg))
        }
      } else {
        spans.append(TerminalStyledSpan(gutter, foreground: ScribePalette.gray, background: bg))
        if lineIdx < visualLines.count, textWidth > 0 {
          spans.append(
            TerminalStyledSpan(
              String(visualLines[lineIdx].prefix(textWidth)), foreground: ScribePalette.white, background: bg))
        }
        if onLastInputRow {
          spans.append(TerminalStyledSpan("▏", foreground: ScribePalette.white, background: bg))
        }
      }
      grid.blitSpans(column: 0, row: row, maxWidth: cols, spans)
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

      var spans: [TerminalStyledSpan] = []
      if lineIdx == 0 {
        spans.append(TerminalStyledSpan("queued: ", foreground: ScribePalette.orange, background: bg))
      } else {
        spans.append(TerminalStyledSpan(gutterText, foreground: ScribePalette.gray, background: bg))
      }
      if textWidth > 0 {
        spans.append(
          TerminalStyledSpan(
            String(visualLines[lineIdx].prefix(textWidth)),
            foreground: ScribePalette.grayLight, background: bg))
      }
      grid.blitSpans(column: 0, row: row, maxWidth: cols, spans)
      lineIdx &+= 1
    }
  }
}

// MARK: - TLine → slate span conversion

extension TLine {
  /// Converts scribe-style ``StyledSpan``s into slate-native ``TerminalStyledSpan``s
  /// for use with ``TerminalCellGrid/blitSpans(column:row:maxWidth:_:)``.
  var toSlateSpans: [TerminalStyledSpan] {
    spans.map { s in
      TerminalStyledSpan(
        s.text,
        foreground: s.fg,
        background: s.bg,
        flags: s.bold ? .bold : [])
    }
  }
}
