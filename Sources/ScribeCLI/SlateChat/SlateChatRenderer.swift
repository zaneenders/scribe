import Foundation
import ScribeCore
import SlateCore

// MARK: - Grid render

/// Renders the full-screen chat grid: transcript, queued tray, input strip, banner, and usage HUD.
///
/// ## Render pipeline & input responsiveness
///
/// Slate's renderer runs on `@MainActor` — the same actor that drains stdin events
/// through the wake pump's `onEvent`. Every render builds a cell grid, encodes it
/// into a single contiguous byte run, and submits it to the controlling tty.
///
/// To keep keystrokes responsive while the model is busy:
///
/// 1. **Slate ships frames through an async writer.** `Slate.enscribe` builds the
///    grid synchronously on the main actor, copies the encoded bytes into an
///    owned `[UInt8]`, and submits them to a detached writer task that performs
///    the actual blocking `write(2)` call(s). The main actor never waits on tty
///    drain. See `Sources/SlateCore/AsyncFrameWriter.swift`.
/// 2. **Frames coalesce on the writer side.** The writer's input stream uses
///    `bufferingPolicy: .bufferingNewest(1)`: while a frame is being written, an
///    incoming frame replaces any older pending frame (latest wins). During a
///    typing burst or fast SSE stream the user always converges to the latest
///    visible state with bounded memory.
/// 3. **External wakes are throttled.** `SlateChat.runFullscreen` configures the
///    pump with `externalCoalesceMaxFramesPerSecond: 60`, so SSE chunks /
///    persistence saves / usage updates produce at most ~60 main-actor renders
///    per second regardless of how busy the producer is.
/// 4. **Slow-frame log line.** `event=chat.render.slow elapsed_ms=… prepare_ms=…
///    submit_ms=… …` fires when the on-actor portion of a render exceeds 50 ms.
///    `prepare_ms` covers transcript flatten + layout (CPU on main actor),
///    `submit_ms` covers grid build + encode + writer submission (also on main
///    actor; the actual tty drain is off-actor and **not** included).
/// 5. **Tool output truncation in the transcript.** `read_file` results render as
///    a single summary line, and shell `stdout` / `stderr` results larger than
///    200 lines render as a head + truncation marker + tail (120 + marker + 60).
///    The full content is preserved in the conversation history sent to the
///    model — the cap only affects the rendered scrollback to keep flatten +
///    layout cost bounded after a verbose tool call.
///
/// ## Queued tray
///
/// The tray sits between the transcript and the input strip, shares the input
/// strip background, indents continuation rows under an 8-space gutter (matching
/// the width of `queued: `), and is hard-capped at 4 rows with trailing `…`
/// truncation so a long queued paste cannot push the transcript off screen.
///
/// - ``queuedTrayRowCount(queuedTrayText:cols:)`` returns the number of rows to
///   reserve for the queued tray strip (0 when no queued message).
/// - ``paintQueuedTrayRows(into:startRow:cols:textWidth:visualLines:theme:)``
///   paints the tray rows: first row prefixed with `queued: ` (orange) plus the
///   message in dimmed white; continuation rows align under the message with an
///   8-space gutter.
@MainActor
internal enum SlateChatRenderer {
  /// Braille spinner (common in TUIs); one cell, advances while waiting for the first token.
  private static let llmWaitSpinner: [Character] = [
    "⣾", "⣽", "⣻", "⢿", "⡿", "⣟", "⣯", "⣷",
  ]

  private static let inputGutterColumns = 6
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
    inputMode: EditMode = .edit,
    llmWaitAnimationFrame: Int,
    waitingForLLM: Bool,
    queuedTrayText: String?,
    theme: CLITheme
  ) -> TerminalCellGrid {
    let fill = TerminalCell(
      glyph: " ", foreground: theme.inputText, background: theme.background, flags: [])
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
      let w = usageHUDCharCount(u, maxRows: headerRows, theme: theme)
      return min(cols, w &+ 1)
    }()
    let bannerMaxWithUsage = usageReserve > 0 ? max(0, cols &- usageReserve) : cols

    if headerRows >= 1 {
      if let banner {
        paintBannerKV(
          into: &grid, row: 0, cols: cols, maxWidth: bannerMaxWithUsage, label: "LLM: ",
          valueSpans: [
            TerminalStyledSpan(
              banner.baseURL, foreground: theme.bannerValue, background: theme.background)
          ], theme: theme)
      }
      if let u = usage {
        paintUsageHUD(into: &grid, cols: cols, usage: u, maxRows: headerRows, theme: theme)
      }
    }

    if headerRows >= 2, let banner {
      let modelWithVersion = "\(banner.model)  v:\(banner.scribeVersion)"
      paintBannerKV(
        into: &grid, row: 1, cols: cols, maxWidth: bannerMaxWithUsage, label: "Model: ",
        valueSpans: [
          TerminalStyledSpan(
            modelWithVersion, foreground: theme.bannerValue, background: theme.background)
        ], theme: theme)
    }
    if headerRows >= 3, let banner {
      let bg = theme.background
      var cwdSpans: [TerminalStyledSpan] = [
        TerminalStyledSpan(banner.cwd, foreground: theme.bannerValue, background: bg)
      ]
      if let branch = banner.gitBranch {
        cwdSpans.append(
          TerminalStyledSpan("@\(branch)", foreground: theme.bannerLabel, background: bg))
      }
      paintBannerKV(
        into: &grid, row: 2, cols: cols, maxWidth: bannerMaxWithUsage, label: "CWD: ",
        valueSpans: cwdSpans, theme: theme)
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
          glyph: " ", foreground: theme.inputText,
          background: theme.inputAreaBg, flags: []))
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
        visualLines: trayVisualLines,
        theme: theme)
    }

    paintInputRows(
      into: &grid,
      startRow: firstInputRow,
      cols: cols,
      textWidth: textWidth,
      visualLines: visualLines,
      rowCount: inputRowCount,
      inputMode: inputMode,
      llmWaitAnimationFrame: llmWaitAnimationFrame,
      showSpinner: showSpinner,
      theme: theme)

    return grid
  }

  private static func formatUsageInt(_ n: Int) -> String {
    ScribeUsageFormatting.groupingInt(n)
  }

  private static func formatUsageIntOpt(_ n: Int?) -> String {
    guard let n else { return "—" }
    return formatUsageInt(n)
  }

  private static func hudSpan(_ fg: TerminalRGB, _ text: String, bg: TerminalRGB, bold: Bool = false)
    -> TerminalStyledSpan
  {
    TerminalStyledSpan(text, foreground: fg, background: bg, flags: bold ? .bold : [])
  }

  /// Up to three lines of spans for the upper-right HUD.  When `maxRows` is small the
  /// optional R/cache row is dropped first so totals stay visible.
  private static func usageHUDSpans(from usage: UsageHUDSnapshot, maxRows: Int, theme: CLITheme)
    -> [[TerminalStyledSpan]]
  {
    let sep = "  ·  "
    let bg = theme.background

    var row0: [TerminalStyledSpan] = [
      hudSpan(theme.usageLabel, "in ", bg: bg),
      hudSpan(theme.usagePrompt, formatUsageIntOpt(usage.roundPrompt), bg: bg),
      hudSpan(theme.usageMuted, sep, bg: bg),
      hudSpan(theme.usageLabel, "out ", bg: bg),
      hudSpan(theme.usageCompletion, formatUsageIntOpt(usage.roundCompletion), bg: bg),
    ]
    if let tps = usage.outputTokensPerSecond {
      row0.append(hudSpan(theme.usageMuted, sep, bg: bg))
      row0.append(hudSpan(theme.usageLabel, "rate ", bg: bg))
      row0.append(hudSpan(theme.usageRate, String(format: "%.1f/s", tps), bg: bg))
    }
    if let pct = usage.contextWindowUsedPercent {
      row0.append(hudSpan(theme.usageMuted, sep, bg: bg))
      row0.append(hudSpan(theme.usageLabel, "ctx ", bg: bg))
      let pctColor: TerminalRGB =
        pct >= 90 ? theme.usageCtxPctDanger : (pct >= 75 ? theme.usageCtxPctWarn : theme.usageCtxPctNormal)
      row0.append(hudSpan(pctColor, "\(pct)%", bg: bg))
    }

    let hasR = (usage.reasoningTokens ?? 0) > 0
    let hasCache = (usage.cachedPromptTokens ?? 0) > 0
    let lineDetail: [TerminalStyledSpan]? = {
      guard hasR || hasCache else { return nil }
      var row1: [TerminalStyledSpan] = []
      if hasR {
        row1.append(hudSpan(theme.usageLabel, "reasoning ", bg: bg))
        row1.append(hudSpan(theme.usageReasoning, formatUsageInt(usage.reasoningTokens!), bg: bg))
      }
      if hasR && hasCache {
        row1.append(hudSpan(theme.usageMuted, sep, bg: bg))
      }
      if hasCache {
        row1.append(hudSpan(theme.usageLabel, "cache ", bg: bg))
        row1.append(hudSpan(theme.usageCache, formatUsageInt(usage.cachedPromptTokens!), bg: bg))
      }
      return row1
    }()

    let lineSums: [TerminalStyledSpan] = [
      hudSpan(theme.usageLabel, "turn Σ ", bg: bg),
      hudSpan(theme.usageTurnSum, formatUsageInt(usage.turnTotal), bg: bg, bold: true),
      hudSpan(theme.usageMuted, sep, bg: bg),
      hudSpan(theme.usageLabel, "all Σ ", bg: bg),
      hudSpan(theme.usageSessionSum, formatUsageInt(usage.sessionTotal), bg: bg, bold: true),
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

  private static func usageHUDCharCount(_ usage: UsageHUDSnapshot, maxRows: Int, theme: CLITheme) -> Int {
    usageHUDSpans(from: usage, maxRows: maxRows, theme: theme)
      .map { $0.reduce(0) { $0 + $1.text.count } }.max() ?? 0
  }

  private static func paintBannerKV(
    into grid: inout TerminalCellGrid,
    row: Int,
    cols: Int,
    maxWidth: Int,
    label: String,
    valueSpans: [TerminalStyledSpan],
    theme: CLITheme
  ) {
    guard row >= 0, row < grid.rows, !valueSpans.isEmpty else { return }
    let bg = theme.background
    let cap = min(max(0, maxWidth), cols)
    let maxValueChars = max(0, cap &- label.count)

    var spans = valueSpans
    let totalChars = spans.reduce(0) { $0 + $1.text.count }
    if totalChars > maxValueChars {
      var budget = maxValueChars
      var trimmed: [TerminalStyledSpan] = []
      for span in spans {
        guard budget > 0 else { break }
        if span.text.count <= budget {
          trimmed.append(span)
          budget -= span.text.count
        } else {
          trimmed.append(
            TerminalStyledSpan(
              String(span.text.prefix(max(0, budget &- 1))) + "…",
              foreground: span.foreground,
              background: span.background,
              flags: span.flags))
          budget = 0
        }
      }
      spans = trimmed
    }

    grid.blitSpans(
      column: 0, row: row, maxWidth: cap,
      [TerminalStyledSpan(label, foreground: theme.bannerLabel, background: bg)] + spans)
  }

  private static func paintUsageHUD(
    into grid: inout TerminalCellGrid,
    cols: Int,
    usage: UsageHUDSnapshot?,
    maxRows: Int,
    theme: CLITheme
  ) {
    guard let usage, maxRows > 0 else { return }
    let lines = usageHUDSpans(from: usage, maxRows: maxRows, theme: theme)
    for (row, spans) in lines.enumerated() {
      guard row >= 0, row < grid.rows else { break }
      let w = spans.reduce(0) { $0 + $1.text.count }
      let startCol = max(0, cols &- w)
      grid.blitSpans(column: startCol, row: row, maxWidth: cols &- startCol, spans)
    }
  }

  /// Paints the input stack: first row shows mode label (`EDIT: ` / `READ: `),
  /// continuation rows gutter-indented; caret on the last row.
  private static func paintInputRows(
    into grid: inout TerminalCellGrid,
    startRow: Int,
    cols: Int,
    textWidth: Int,
    visualLines: [String],
    rowCount: Int,
    inputMode: EditMode = .edit,
    llmWaitAnimationFrame: Int,
    showSpinner: Bool,
    theme: CLITheme
  ) {
    let bg = theme.inputAreaBg
    let gutter = String(repeating: " ", count: min(inputGutterColumns, cols))
    // Mode label: "EDIT: " in userPrefix (orange), "READ: " in scribePrefix (white)
    let modeLabel = inputMode == .edit ? "EDIT: " : "READ: "
    let modeColor = inputMode == .edit ? theme.userPrefix : theme.scribePrefix
    var lineIdx = 0
    while lineIdx < rowCount {
      let row = startRow &+ lineIdx
      guard row >= 0, row < grid.rows else { break }
      let onLastInputRow = lineIdx == rowCount &- 1

      var spans: [TerminalStyledSpan] = []
      if showSpinner, onLastInputRow {
        spans.append(TerminalStyledSpan("scribe: ", foreground: theme.scribePrefix, background: bg))
        let frames = llmWaitSpinner
        let ch = frames[llmWaitAnimationFrame % frames.count]
        spans.append(TerminalStyledSpan(String(ch), foreground: theme.spinnerGlyph, background: bg))
        spans.append(TerminalStyledSpan("▏", foreground: theme.inputCursor, background: bg))
      } else if lineIdx == 0 {
        spans.append(TerminalStyledSpan(modeLabel, foreground: modeColor, background: bg))
        if lineIdx < visualLines.count, textWidth > 0 {
          spans.append(
            TerminalStyledSpan(
              String(visualLines[lineIdx].prefix(textWidth)), foreground: theme.inputText, background: bg))
        }
        if onLastInputRow {
          spans.append(TerminalStyledSpan("▏", foreground: theme.inputCursor, background: bg))
        }
      } else {
        spans.append(TerminalStyledSpan(gutter, foreground: theme.inputGutter, background: bg))
        if lineIdx < visualLines.count, textWidth > 0 {
          spans.append(
            TerminalStyledSpan(
              String(visualLines[lineIdx].prefix(textWidth)), foreground: theme.inputText, background: bg))
        }
        if onLastInputRow {
          spans.append(TerminalStyledSpan("▏", foreground: theme.inputCursor, background: bg))
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
    visualLines: [String],
    theme: CLITheme
  ) {
    guard !visualLines.isEmpty else { return }
    let bg = theme.inputAreaBg
    let gutterText = String(repeating: " ", count: min(queuedTrayGutterColumns, cols))
    var lineIdx = 0
    while lineIdx < visualLines.count {
      let row = startRow &+ lineIdx
      guard row >= 0, row < grid.rows else { break }

      var spans: [TerminalStyledSpan] = []
      if lineIdx == 0 {
        spans.append(TerminalStyledSpan("queued: ", foreground: theme.queuedPrefix, background: bg))
      } else {
        spans.append(TerminalStyledSpan(gutterText, foreground: theme.queuedGutter, background: bg))
      }
      if textWidth > 0 {
        spans.append(
          TerminalStyledSpan(
            String(visualLines[lineIdx].prefix(textWidth)),
            foreground: theme.queuedText, background: bg))
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
