import Foundation
import ScribeCore
import ScribeLLM
import SlateCore
import Synchronization

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

// MARK: - User input

private actor UserLineGate {
  private var waiting: CheckedContinuation<String?, Never>?

  func nextLine() async -> String? {
    await withCheckedContinuation { cont in
      waiting = cont
    }
  }

  func complete(_ line: String?) {
    waiting?.resume(returning: line)
    waiting = nil
  }
}

// MARK: - Transcript model (thread-safe for streaming + render)

private struct StyledSpan: Equatable {
  var fg: TerminalRGB
  var bg: TerminalRGB
  var bold: Bool
  var text: String
}

private struct TLine: Equatable {
  var spans: [StyledSpan]
}

/// Standalone transcript header (parity with purple ``scribe:``).
private let slateUserTranscriptHeader = "you:"

/// Indents user message lines under ``slateUserTranscriptHeader`` (same as ``  · reasoning``).
private let slateUserTranscriptBodyPrefix = "  "

private func slateIsYouTranscriptHeaderLine(_ line: TLine) -> Bool {
  guard line.spans.count == 1 else { return false }
  let s = line.spans[0]
  return !s.bold
    && s.fg == ScribePalette.orange
    && s.bg == ScribePalette.black
    && s.text == slateUserTranscriptHeader
}

private func slateIsUserTranscriptBodyLine(_ line: TLine) -> Bool {
  guard let s = line.spans.first, !s.bold, s.bg == ScribePalette.black else { return false }
  guard s.fg == ScribePalette.white else { return false }
  return s.text.hasPrefix(slateUserTranscriptBodyPrefix)
}

/// Any scrollback line that belongs to a submitted user turn (header or body).
private func slateIsUserSubmissionLine(_ line: TLine) -> Bool {
  slateIsYouTranscriptHeaderLine(line) || slateIsUserTranscriptBodyLine(line)
}

/// Latest usage for the fixed top row (not part of scrollback).
private struct UsageHUDSnapshot: Equatable {
  var prompt: Int?
  var completion: Int?
  var total: Int?
  var outputTokensPerSecond: Double?
}

/// Config header fixed at the top (not scrollback).
private struct BannerSnapshot: Equatable {
  var baseURL: String
  var model: String
  var cwd: String
}

private struct SinkState {
  var lines: [TLine] = []
  var assistantOpenLine: TLine?
  var wake: ExternalWake?
  var modelBusy: Bool = false
  var coordinatorFinished: Bool = false
  var usageHUD: UsageHUDSnapshot?
  var banner: BannerSnapshot?
}

/// Slate-backed transcript sink: same information as ``TerminalScribeOutput``, with truecolor preserved in the grid.
public final class SlateTranscriptSink: ScribeAgentOutput, @unchecked Sendable {
  private let state = Mutex(SinkState())

  public init() {}

  private func ping() {
    state.withLock { $0.wake?.requestRender() }
  }

  public func installWake(_ wake: ExternalWake) {
    state.withLock { $0.wake = wake }
  }

  public func markCoordinatorFinished() {
    state.withLock { $0.coordinatorFinished = true }
    ping()
  }

  public func coordinatorFinished() -> Bool {
    state.withLock { $0.coordinatorFinished }
  }

  public func modelTurnBusy() -> Bool {
    state.withLock { $0.modelBusy }
  }

  fileprivate func snapshotTranscriptForLayout() -> (completed: [TLine], open: TLine?) {
    state.withLock { sink in
      (sink.lines, sink.assistantOpenLine)
    }
  }

  fileprivate func snapshotLines() -> [TLine] {
    state.withLock { sink in
      var out = sink.lines
      if let open = sink.assistantOpenLine {
        out.append(open)
      }
      return out
    }
  }

  fileprivate func usageHUDSnapshot() -> UsageHUDSnapshot? {
    state.withLock { $0.usageHUD }
  }

  fileprivate func bannerSnapshot() -> BannerSnapshot? {
    state.withLock { $0.banner }
  }

  /// Records a submitted user turn in the scrollback (trimmed text matches what the coordinator sends to the model).
  public func recordUserSubmission(trimmedVisible: String) {
    guard !trimmedVisible.isEmpty else { return }
    let logicalLines =
      trimmedVisible.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    state.withLock { sink in
      sink.lines.append(
        TLine(
          spans: [
            StyledSpan(
              fg: ScribePalette.orange, bg: ScribePalette.black, bold: false,
              text: slateUserTranscriptHeader)
          ]))
      for row in logicalLines {
        if row.isEmpty {
          sink.lines.append(TLine(spans: []))
          continue
        }
        sink.lines.append(
          TLine(
            spans: [
              StyledSpan(
                fg: ScribePalette.white, bg: ScribePalette.black, bold: false,
                text: slateUserTranscriptBodyPrefix + row)
            ]))
      }
      trimIfNeeded(&sink.lines)
    }
    ping()
  }

  private func appendLine(_ line: TLine) {
    state.withLock { sink in
      sink.lines.append(line)
      trimIfNeeded(&sink.lines)
    }
    ping()
  }

  private func trimIfNeeded(_ lines: inout [TLine]) {
    let cap = 4_000
    if lines.count > cap {
      lines.removeFirst(lines.count - cap)
    }
  }

  private static func style(for section: AssistantStreamSection) -> (fg: TerminalRGB, bold: Bool) {
    switch section {
    case .reasoning: (ScribePalette.thinking, true)
    case .answer: (ScribePalette.cyan, false)
    }
  }

  private static func appendText(to line: inout TLine, fg: TerminalRGB, bg: TerminalRGB, bold: Bool, text: String) {
    guard !text.isEmpty else { return }
    if var last = line.spans.last, last.fg == fg, last.bg == bg, last.bold == bold {
      last.text += text
      line.spans[line.spans.count - 1] = last
    } else {
      line.spans.append(StyledSpan(fg: fg, bg: bg, bold: bold, text: text))
    }
  }

  public func markModelTurnRunning(_ running: Bool) throws {
    state.withLock { sink in
      sink.modelBusy = running
      // New model turn: drop last turn's throughput so the HUD isn't stuck showing a stale "out/s"
      // until this stream finishes (and turn boundaries read clearly in the fixed header).
      if running, var u = sink.usageHUD {
        u.outputTokensPerSecond = nil
        sink.usageHUD = u
      }
    }
    ping()
  }

  public func printConfigBanner(baseURL: String, model: String, cwd: String) {
    state.withLock { sink in
      sink.banner = BannerSnapshot(baseURL: baseURL, model: model, cwd: cwd)
    }
    ping()
  }

  public func printUserPromptDecoration() {}

  public func enterAssistantStreamSection(
    _ section: AssistantStreamSection,
    previous: AssistantStreamSection?
  ) throws {
    state.withLock { sink in
      if previous != nil {
        if let open = sink.assistantOpenLine {
          sink.lines.append(open)
          sink.assistantOpenLine = nil
        }
        if previous == .reasoning && section == .answer {
          sink.lines.append(TLine(spans: []))
        }
      } else {
        if let last = sink.lines.last, slateIsUserSubmissionLine(last) {
          sink.lines.append(TLine(spans: []))
        }
      }

      let header = TLine(
        spans: [
          StyledSpan(
            fg: ScribePalette.purple, bg: ScribePalette.black, bold: false, text: "scribe:")
        ])
      sink.lines.append(header)
      switch section {
      case .reasoning:
        sink.lines.append(
          TLine(
            spans: [
              StyledSpan(
                fg: ScribePalette.grayDim, bg: ScribePalette.black, bold: false, text: "  · reasoning")
            ]))
      case .answer:
        sink.lines.append(
          TLine(
            spans: [
              StyledSpan(
                fg: ScribePalette.grayDim, bg: ScribePalette.black, bold: false, text: "  · answer")
            ]))
      }
      trimIfNeeded(&sink.lines)

      sink.assistantOpenLine = TLine(spans: [])
    }
    ping()
  }

  public func appendAssistantStreamText(_ section: AssistantStreamSection, text: String) throws {
    let st = Self.style(for: section)
    let parts = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    for (i, part) in parts.enumerated() {
      state.withLock { sink in
        if sink.assistantOpenLine == nil {
          sink.assistantOpenLine = TLine(spans: [])
        }
        Self.appendText(
          to: &sink.assistantOpenLine!, fg: st.fg, bg: ScribePalette.black, bold: st.bold, text: part)
        if i + 1 < parts.count {
          if let open = sink.assistantOpenLine {
            sink.lines.append(open)
            sink.assistantOpenLine = TLine(spans: [])
          }
        }
      }
      ping()
    }
  }

  public func finalizeAssistantStreamIfNeeded(streamHadVisibleTokens: Bool) throws {
    guard streamHadVisibleTokens else { return }
    state.withLock { sink in
      if let open = sink.assistantOpenLine {
        sink.lines.append(open)
        sink.assistantOpenLine = nil
      }
      trimIfNeeded(&sink.lines)
    }
    ping()
  }

  public func printEmptyAssistantTurn() throws {
    let lineA = TLine(
      spans: [
        StyledSpan(
          fg: ScribePalette.purple, bg: ScribePalette.black, bold: false, text: "scribe:")
      ])
    let lineB = TLine(
      spans: [
        StyledSpan(
          fg: ScribePalette.grayDim, bg: ScribePalette.black, bold: false, text: "(empty turn)")
      ])
    state.withLock { sink in
      sink.lines.append(lineA)
      sink.lines.append(lineB)
      trimIfNeeded(&sink.lines)
    }
    ping()
  }

  public func emitUsage(
    promptTokens: Int?,
    completionTokens: Int?,
    totalTokens: Int?,
    outputTokensPerSecond: Double?
  ) throws {
    guard promptTokens != nil || completionTokens != nil || totalTokens != nil else { return }
    state.withLock { sink in
      sink.usageHUD = UsageHUDSnapshot(
        prompt: promptTokens,
        completion: completionTokens,
        total: totalTokens,
        outputTokensPerSecond: outputTokensPerSecond)
    }
    ping()
  }

  public func printBlankLine() throws {
    appendLine(TLine(spans: []))
  }

  public func printToolRoundHeader(round: Int, toolNames: [String]) throws {
    let names = toolNames.joined(separator: ", ")
    let line = TLine(spans: [
      StyledSpan(
        fg: ScribePalette.yellow, bg: ScribePalette.black, bold: true,
        text: "tool round \(round) "),
      StyledSpan(
        fg: ScribePalette.toolName, bg: ScribePalette.black, bold: false, text: names),
    ])
    appendLine(line)
  }

  public func printToolInvocation(
    name: String,
    argumentSummary: String?,
    outputLines: [String]
  ) throws {
    var spans: [StyledSpan] = [
      StyledSpan(fg: ScribePalette.yellow, bg: ScribePalette.black, bold: false, text: "▶ \(name)")
    ]
    if let argumentSummary {
      spans.append(
        StyledSpan(
          fg: ScribePalette.grayDim, bg: ScribePalette.black, bold: false,
          text: " \(argumentSummary)"))
    }
    appendLine(TLine(spans: spans))
    for ol in outputLines {
      let indented =
        TLine(
          spans: [
            StyledSpan(
              fg: ScribePalette.white, bg: ScribePalette.black, bold: false,
              text: "  \(ol)")
          ])
      appendLine(indented)
    }
  }

  public func printMaxToolRoundsExceeded(max: Int) throws {
    appendLine(
      TLine(
        spans: [
          StyledSpan(
            fg: ScribePalette.yellow, bg: ScribePalette.black, bold: false,
            text: "Stopped: max tool rounds (\(max)) exceeded.")
        ]))
  }

  public func printSkippedUnreadableStreamLine() throws {
    appendLine(
      TLine(
        spans: [
          StyledSpan(
            fg: ScribePalette.grayDim, bg: ScribePalette.black, bold: false,
            text: "(skipped one stream line: not valid completion JSON)")
        ]))
  }

  public func printHarnessRunError(_ error: Error) throws {
    appendLine(
      TLine(
        spans: [
          StyledSpan(
            fg: ScribePalette.red, bg: ScribePalette.black, bold: false,
            text: "error: \(error)")
        ]))
  }
}

// MARK: - Layout

private enum TranscriptLayout {
  private struct RunStyle: Equatable {
    var fg: TerminalRGB
    var bg: TerminalRGB
    var bold: Bool
  }

  private static func runStyle(from s: StyledSpan) -> RunStyle {
    RunStyle(fg: s.fg, bg: s.bg, bold: s.bold)
  }

  private static func wrappedPlainLines(_ text: String, width: Int) -> [String] {
    guard width > 0 else { return [] }
    if text.isEmpty { return [""] }
    var lines: [String] = []
    var current = ""

    func flush() {
      if !current.isEmpty {
        lines.append(current)
        current = ""
      }
    }

    for word in text.split(separator: " ", omittingEmptySubsequences: false) {
      let w = String(word)
      let sep = current.isEmpty ? "" : " "
      let candidate = current + sep + w
      if candidate.count <= width {
        current = candidate
        continue
      }

      flush()

      if w.count <= width {
        current = w
        continue
      }

      var rest = Substring(w)
      while !rest.isEmpty {
        let take = min(width, rest.count)
        lines.append(String(rest.prefix(take)))
        rest = rest.dropFirst(take)
      }
    }

    flush()
    // Strings that are only U+0020 spaces split into empty chunks above, leaving `lines` empty.
    // That drops blank transcript rows (`you:` continuation with no trailing text).
    if lines.isEmpty, !text.isEmpty {
      var remainder = Substring(text)
      while remainder.count > width {
        lines.append(String(remainder.prefix(width)))
        remainder = remainder.dropFirst(width)
      }
      lines.append(String(remainder))
    }

    return lines
  }

  /// Wrapped display lines for the input buffer (logical newlines + word wrap).
  static func inputVisualLines(from buffer: String, textWidth: Int) -> [String] {
    guard textWidth > 0 else { return buffer.isEmpty ? [""] : [] }
    if buffer.isEmpty { return [""] }
    var rows: [String] = []
    for logical in buffer.split(separator: "\n", omittingEmptySubsequences: false) {
      let wrapped = wrappedPlainLines(String(logical), width: textWidth)
      rows.append(contentsOf: wrapped)
    }
    return rows
  }

  /// Flattens styled transcript lines into wrapped rows of ``TLine``.
  static func flattenedRows(from lines: [TLine], width: Int) -> [TLine] {
    guard width > 0 else { return [] }
    var out: [TLine] = []
    for line in lines {
      if line.spans.isEmpty {
        out.append(TLine(spans: []))
        continue
      }

      var plain = ""
      var styles: [RunStyle] = []
      for sp in line.spans {
        for ch in sp.text {
          plain.append(ch)
          styles.append(runStyle(from: sp))
        }
      }

      if plain.isEmpty {
        out.append(TLine(spans: []))
        continue
      }

      let chars = Array(plain)
      precondition(chars.count == styles.count)

      var i = 0
      while i < chars.count {
        var j = i
        while j < chars.count, chars[j] != "\n" {
          j &+= 1
        }

        let part = chars[i..<j]
        if !part.isEmpty {
          let wrapped = wrappedPlainLines(String(part), width: width)
          var charOffset = i
          for segment in wrapped {
            let sliceStyles = styles[charOffset..<(charOffset + segment.count)]
            charOffset += segment.count
            var newLine = TLine(spans: [])
            for (style, ch) in zip(sliceStyles, segment) {
              SlateTranscriptSinkAppendSpan(
                &newLine, fg: style.fg, bg: style.bg, bold: style.bold, char: ch)
            }
            out.append(newLine)
          }
        } else if j < chars.count {
          out.append(TLine(spans: []))
        }

        guard j < chars.count else { break }
        i = j &+ 1
      }
    }
    return out
  }
}

/// Helper to append one character span (file-private linkage to avoid exposing on sink).
private func SlateTranscriptSinkAppendSpan(
  _ line: inout TLine, fg: TerminalRGB, bg: TerminalRGB, bold: Bool, char: Character
) {
  if var last = line.spans.last, last.fg == fg, last.bg == bg, last.bold == bold {
    last.text.append(char)
    line.spans[line.spans.count - 1] = last
  } else {
    line.spans.append(StyledSpan(fg: fg, bg: bg, bold: bold, text: String(char)))
  }
}

// MARK: - Grid render

@MainActor
private enum SlateChatRenderer {
  /// Braille spinner (common in TUIs); one cell, advances while waiting for the first token.
  private static let llmWaitSpinner: [Character] = [
    "⣾", "⣽", "⣻", "⢿", "⡿", "⣟", "⣯", "⣷",
  ]

  private static let inputGutterColumns = 5

  /// Rows available for transcript text between the fixed header and the input stack (matches ``makeGrid``).
  static func transcriptContentRows(
    cols: Int,
    rows: Int,
    banner: BannerSnapshot?,
    usage: UsageHUDSnapshot?,
    inputLine: String,
    waitingForLLM: Bool
  ) -> Int {
    let headerRows: Int = {
      if banner != nil {
        return min(3, max(0, rows &- 1))
      }
      if usage != nil, rows >= 2 {
        return 1
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

    let firstInputRow = rows &- inputRowCount
    return max(0, firstInputRow &- headerRows)
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
    waitingForLLM: Bool
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
        return 1
      }
      return 0
    }()

    let contentRows = transcriptContentRows(
      cols: cols, rows: rows, banner: banner, usage: usage,
      inputLine: inputLine, waitingForLLM: waitingForLLM)

    if headerRows >= 1 {
      let usageReserve: Int
      if let u = usage {
        usageReserve = min(cols, usageHUDCharCount(u) &+ 1)
      } else {
        usageReserve = 0
      }
      let llmMax = max(0, cols &- usageReserve)

      if let banner {
        paintBannerKV(
          into: &grid, row: 0, cols: cols, maxWidth: llmMax, label: "LLM: ", value: banner.baseURL)
      }
      if let u = usage {
        paintUsageHUD(into: &grid, cols: cols, usage: u)
      }
    }

    if headerRows >= 2, let banner {
      paintBannerKV(
        into: &grid, row: 1, cols: cols, maxWidth: cols, label: "Model: ", value: banner.model)
    }
    if headerRows >= 3, let banner {
      paintBannerKV(
        into: &grid, row: 2, cols: cols, maxWidth: cols, label: "CWD: ", value: banner.cwd)
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
    let wrapW = cols

    fillInputBackground(
      into: &grid, startRow: firstInputRow, rowCount: inputRowCount, cols: cols,
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
        guard y < firstInputRow else { break }
        blit(line: line, into: &grid, column: 0, row: y, width: wrapW)
        y &+= 1
      }
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

  private static func usageHUDLine(from usage: UsageHUDSnapshot) -> TLine {
    let inStr = usage.prompt.map(String.init) ?? "—"
    let outStr = usage.completion.map(String.init) ?? "—"
    let sumStr = usage.total.map(String.init) ?? "—"
    let rateStr = usage.outputTokensPerSecond.map { String(format: "%.1f", $0) + " out/s" }
    let m = ScribePalette.usageMuted
    let ni = ScribePalette.usageInOut
    let ns = ScribePalette.usageSum
    var spans: [StyledSpan] = [
      StyledSpan(fg: m, bg: ScribePalette.black, bold: false, text: "· "),
      StyledSpan(fg: ni, bg: ScribePalette.black, bold: false, text: inStr),
      StyledSpan(fg: m, bg: ScribePalette.black, bold: false, text: " in · "),
      StyledSpan(fg: ni, bg: ScribePalette.black, bold: false, text: outStr),
      StyledSpan(fg: m, bg: ScribePalette.black, bold: false, text: " out"),
    ]
    if let rateStr {
      spans.append(StyledSpan(fg: m, bg: ScribePalette.black, bold: false, text: " · "))
      spans.append(StyledSpan(fg: ni, bg: ScribePalette.black, bold: false, text: rateStr))
    }
    spans.append(StyledSpan(fg: m, bg: ScribePalette.black, bold: false, text: " · Σ "))
    spans.append(StyledSpan(fg: ns, bg: ScribePalette.black, bold: true, text: sumStr))
    spans.append(StyledSpan(fg: m, bg: ScribePalette.black, bold: false, text: " ·"))
    return TLine(spans: spans)
  }

  private static func usageHUDCharCount(_ usage: UsageHUDSnapshot) -> Int {
    usageHUDLine(from: usage).spans.reduce(0) { $0 + $1.text.count }
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
    usage: UsageHUDSnapshot?
  ) {
    guard let usage else { return }
    let line = usageHUDLine(from: usage)
    let w = line.spans.reduce(0) { $0 + $1.text.count }
    let startCol = max(0, cols &- w)
    blit(line: line, into: &grid, column: startCol, row: 0, width: cols - startCol)
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

// MARK: - Host

/// Arrow / page keys mapped to transcript viewport motion (CSI, xterm-style).
private enum TranscriptScrollStep {
  case lineUp
  case lineDown
  case pageUp
  case pageDown
  /// ``ESC [ F`` (empty params): follow live tail / newest content.
  case snapToLiveBottom
  /// ``ESC [ H`` (empty params): jump to oldest buffered history in view.
  case snapToHistoryTop
}

/// Incremental word-wrap flatten of completed transcript lines (streaming only re-wraps the open tail).
private struct TranscriptFlattenCache {
  var wrapWidth: Int = -1
  var completedLogicalLines: Int = 0
  var completedFlat: [TLine] = []
}

@MainActor
private final class SlateChatHost {

  /// Xterm-compatible CSI final byte (`0x40`…`0x7E`): ends `\e[` parameter sequences incl. `…~` paste markers and `…u` kitty-style keys.
  /// Caller must require `accumulator.count >= 3` so `\e[` alone is not mistaken for complete CSI—the `[` byte (0x5B) sits in `0x40`…`0x7E`.
  private static func isCsiTerminator(_ byte: UInt8) -> Bool {
    byte >= 0x40 && byte <= 0x7E
  }

  private static let bracketPasteOpenSeq: ContiguousArray<UInt8> = [27, 91, 50, 48, 48, 126]
  private static let bracketPasteCloseSeq: ContiguousArray<UInt8> = [27, 91, 50, 48, 49, 126]

  /// Recognizes `\e[A` / `\e[B`, `\e[5~` / `\e[6~`, and bare `\e[H` / `\e[F` (cursor keys / paging / Home / End).
  private static func parseTranscriptScrollStep(fromCSI bytes: ContiguousArray<UInt8>) -> TranscriptScrollStep? {
    guard bytes.count >= 3, bytes[0] == 27, bytes[1] == 91 else { return nil }
    let terminator = bytes[bytes.count - 1]

    let paramRegion = bytes[2..<(bytes.count - 1)]
    guard let inner = String(bytes: paramRegion, encoding: .utf8) else { return nil }
    let ints = inner.split(separator: ";").compactMap { Int($0) }

    switch terminator {
    case UInt8(ascii: "A"):
      return .lineUp
    case UInt8(ascii: "B"):
      return .lineDown
    case UInt8(ascii: "H"):
      guard inner.isEmpty else { return nil }
      return .snapToHistoryTop
    case UInt8(ascii: "F"):
      guard inner.isEmpty else { return nil }
      return .snapToLiveBottom
    case UInt8(ascii: "~"):
      guard let k = ints.first else { return nil }
      if k == 5 { return .pageUp }
      if k == 6 { return .pageDown }
      return nil
    default:
      return nil
    }
  }

  private let configuration: AgentConfig
  private let client: Client
  private let systemPrompt: String
  private var inputBuffer = ""
  /// Index into the flattened transcript of the top row of the transcript viewport (used when ``followingLiveTranscript`` is false).
  private var transcriptFirstVisibleRow: Int = 0
  /// When true, the viewport follows the live tail (new tokens stay at the bottom). When false, ``transcriptFirstVisibleRow`` is fixed so streaming does not move the view.
  private var followingLiveTranscript: Bool = true
  private var flattenCache = TranscriptFlattenCache()
  /// Incomplete `\e`-led sequence (`\e[` CSI until terminator, or `\e` + immediate non-`[` char).
  private var escAccumulator: ContiguousArray<UInt8>?
  private var utf8Staging: ContiguousArray<UInt8> = []
  /// After a CR submit (`\r`), swallow the lone `\n` of a CRLF pair.
  private var swallowLfAfterCrSubmit = false
  private var bracketedPasteActive = false
  private var bracketCloseMatchPrefix = 0
  private var renderWake: ExternalWake?
  private var llmWaitAnimationFrame: Int = 0
  private var spinnerTask: Task<Void, Never>?

  init(configuration: AgentConfig, client: Client, systemPrompt: String) {
    self.configuration = configuration
    self.client = client
    self.systemPrompt = systemPrompt
  }

  deinit {
    spinnerTask?.cancel()
  }

  func run() async throws {
    let slate = try Slate()
    let sink = SlateTranscriptSink()
    let gate = UserLineGate()
    var coordinatorTask: Task<Void, Never>?

    // Bracketed paste: pasted text (possibly multi-byte or multi-line) is wrapped so newlines aren’t mistaken for submits.
    try? FileHandle.standardOutput.write(contentsOf: Data("\u{001b}[?2004h".utf8))
    defer {
      try? FileHandle.standardOutput.write(contentsOf: Data("\u{001b}[?2004l".utf8))
    }

    // `externalCoalesceMaxFramesPerSecond: 0` disables throttling for `ExternalWake`. The default
    // coalesces wakes (~60/s), which can drop the post-turn "model finished" render; the UI then
    // keeps the LLM spinner on the input row until another key event or resize even though
    // `markModelTurnRunning(false)` already ran (turn is back on the user).
    await slate.start(
      prepare: { [self] wake in
        sink.installWake(wake)
        self.renderWake = wake
        coordinatorTask = Task { [configuration, client, systemPrompt, sink, gate] in
          defer { sink.markCoordinatorFinished() }
          do {
            try await ScribeAgentCoordinator.runInteractive(
              configuration: configuration,
              client: client,
              systemPrompt: systemPrompt,
              sink: sink,
              readUserLine: { await gate.nextLine() }
            )
          } catch {
            try? sink.printHarnessRunError(error)
          }
        }
        self.spinnerTask?.cancel()
        self.spinnerTask = Task { [weak self] in
          while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(90))
            guard let self else { return }
            guard sink.modelTurnBusy() else { continue }
            self.llmWaitAnimationFrame &+= 1
            self.renderWake?.requestRender()
          }
        }
        wake.requestRender()
      },
      externalCoalesceMaxFramesPerSecond: 0,
      onEvent: { event in
        switch event {
        case .resize:
          slate.refreshWindowSize()
        case .external:
          break
        case .stdinBytes(let chunk):
          if sink.coordinatorFinished() { return .stop }
          if chunk.isEmpty {
            Task { await gate.complete(nil) }
            return .stop
          }
          for byte in chunk {
            if sink.coordinatorFinished() {
              Task { await gate.complete(nil) }
              return .stop
            }
            if self.handleKey(byte: byte, sink: sink, gate: gate, slate: slate) {
              Task { await gate.complete(nil) }
              return .stop
            }
          }
        }
        let flatTranscript = self.syncFlattenedTranscript(sink: sink, slate: slate)
        let contentRows = SlateChatRenderer.transcriptContentRows(
          cols: slate.cols,
          rows: slate.rows,
          banner: sink.bannerSnapshot(),
          usage: sink.usageHUDSnapshot(),
          inputLine: self.inputBuffer,
          waitingForLLM: sink.modelTurnBusy()
        )
        let maxTailStart = max(0, flatTranscript.count &- contentRows)
        if self.followingLiveTranscript {
          self.transcriptFirstVisibleRow = maxTailStart
        } else {
          self.transcriptFirstVisibleRow = min(self.transcriptFirstVisibleRow, maxTailStart)
        }
        let transcriptTailStart = self.transcriptFirstVisibleRow
        slate.enscribe(
          grid: SlateChatRenderer.makeGrid(
            cols: slate.cols,
            rows: slate.rows,
            flattenedTranscript: flatTranscript,
            transcriptTailStart: transcriptTailStart,
            banner: sink.bannerSnapshot(),
            usage: sink.usageHUDSnapshot(),
            inputLine: self.inputBuffer,
            llmWaitAnimationFrame: self.llmWaitAnimationFrame,
            waitingForLLM: sink.modelTurnBusy()))
        return sink.coordinatorFinished() ? .stop : .continue
      })

    spinnerTask?.cancel()
    spinnerTask = nil
    renderWake = nil

    coordinatorTask?.cancel()
    await gate.complete(nil)
  }

  private func submitUserLine(sink: SlateTranscriptSink, gate: UserLineGate) {
    swallowLfAfterCrSubmit = true
    followingLiveTranscript = true
    transcriptFirstVisibleRow = 0
    let submit = inputBuffer
    inputBuffer = ""
    let trimmedVisible = submit.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmedVisible.isEmpty {
      sink.recordUserSubmission(trimmedVisible: trimmedVisible)
    }
    utf8Staging.removeAll(keepingCapacity: true)
    Task {
      await gate.complete(submit)
    }
  }

  /// Recomputes word-wrapped transcript rows, reusing flatten work for completed lines across streaming frames.
  private func syncFlattenedTranscript(sink: SlateTranscriptSink, slate: Slate) -> [TLine] {
    let (completed, open) = sink.snapshotTranscriptForLayout()
    let width = slate.cols

    if width != flattenCache.wrapWidth {
      flattenCache = TranscriptFlattenCache()
      flattenCache.wrapWidth = width
      flattenCache.completedFlat = TranscriptLayout.flattenedRows(from: completed, width: width)
      flattenCache.completedLogicalLines = completed.count
    } else if completed.count < flattenCache.completedLogicalLines {
      flattenCache.completedFlat = TranscriptLayout.flattenedRows(from: completed, width: width)
      flattenCache.completedLogicalLines = completed.count
    } else if completed.count > flattenCache.completedLogicalLines {
      let start = flattenCache.completedLogicalLines
      if start < completed.count {
        let newSlice = completed[start...]
        flattenCache.completedFlat.append(
          contentsOf: TranscriptLayout.flattenedRows(from: Array(newSlice), width: width))
      }
      flattenCache.completedLogicalLines = completed.count
    }

    if let open {
      return flattenCache.completedFlat
        + TranscriptLayout.flattenedRows(from: [open], width: width)
    }
    return flattenCache.completedFlat
  }

  private func applyTranscriptScroll(
    _ step: TranscriptScrollStep,
    sink: SlateTranscriptSink,
    slate: Slate
  ) {
    let flat = syncFlattenedTranscript(sink: sink, slate: slate)
    let contentRows = SlateChatRenderer.transcriptContentRows(
      cols: slate.cols,
      rows: slate.rows,
      banner: sink.bannerSnapshot(),
      usage: sink.usageHUDSnapshot(),
      inputLine: inputBuffer,
      waitingForLLM: sink.modelTurnBusy()
    )
    let page = max(1, contentRows)
    let maxTailStart = max(0, flat.count &- contentRows)

    switch step {
    case .snapToLiveBottom:
      followingLiveTranscript = true
      transcriptFirstVisibleRow = maxTailStart
    case .snapToHistoryTop:
      followingLiveTranscript = false
      transcriptFirstVisibleRow = 0
    case .lineUp, .pageUp:
      let delta = step == .lineUp ? 1 : page
      let wasFollowing = followingLiveTranscript
      followingLiveTranscript = false
      if wasFollowing {
        transcriptFirstVisibleRow = max(0, maxTailStart &- delta)
      } else {
        transcriptFirstVisibleRow = max(0, transcriptFirstVisibleRow &- delta)
      }
    case .lineDown, .pageDown:
      let delta = step == .lineDown ? 1 : page
      transcriptFirstVisibleRow = min(transcriptFirstVisibleRow &+ delta, maxTailStart)
      if transcriptFirstVisibleRow >= maxTailStart {
        followingLiveTranscript = true
      }
    }
    renderWake?.requestRender()
  }

  /// Returns `true` if the enclosing app should terminate (interrupt / EOF semantics).
  private func handleKey(byte: UInt8, sink: SlateTranscriptSink, gate: UserLineGate, slate: Slate) -> Bool {
    if byte == 3 || byte == 4 { return true }

    if bracketedPasteActive {
      ingestBracketPasteByte(byte)
      return false
    }

    if var seq = escAccumulator {
      seq.append(byte)
      if seq.count >= 2, seq.first == 27, seq[1] != 91 {
        // `\e` + non-CSI: historically Option/Alt+Return sent ESC then CR/LF.
        escAccumulator = nil
        if sink.modelTurnBusy() {
          swallowLfAfterCrSubmit = false
          return false
        }
        if byte == 10 || byte == 13 {
          inputBuffer.append("\n")
        } else {
          ingestUtf8Continuation(byte)
        }
        swallowLfAfterCrSubmit = false
        return false
      }
      escAccumulator = seq
      // Need at least `\e[<final>` — the `[` byte (0x5B) is in the terminator range (`0x40`…`0x7E`)
      // but is part of CSI's two-byte introducer, not the final parameter byte.
      if seq.count >= 3, seq[0] == 27, seq[1] == 91, let last = seq.last {
        if Self.isCsiTerminator(last) {
          escAccumulator = nil
          swallowLfAfterCrSubmit = false
          if let scroll = Self.parseTranscriptScrollStep(fromCSI: seq) {
            applyTranscriptScroll(scroll, sink: sink, slate: slate)
            return false
          }
          if sink.modelTurnBusy() {
            return false
          }
          handleTerminatedCSI(seq, sink: sink, gate: gate)
          return false
        }
      }
      return false
    }

    if byte == 27 {
      escAccumulator = [27]
      return false
    }

    if sink.modelTurnBusy() {
      swallowLfAfterCrSubmit = false
      return false
    }

    if byte == 10, swallowLfAfterCrSubmit {
      swallowLfAfterCrSubmit = false
      return false
    }
    if byte != 10 {
      swallowLfAfterCrSubmit = false
    }

    switch byte {
    case 13:
      submitUserLine(sink: sink, gate: gate)
    case 10:
      inputBuffer.append("\n")
    case 8, 127:
      removeLastLogicalCharacterFromInput()
    default:
      ingestUtf8Continuation(byte)
    }

    return false
  }

  /// Drop the last grapheme from the editable line (including staged UTF‑8 tails).
  private func removeLastLogicalCharacterFromInput() {
    guard !utf8Staging.isEmpty else {
      guard !inputBuffer.isEmpty else { return }
      inputBuffer.removeLast()
      return
    }

    utf8Staging.removeLast()
    while utf8Staging.count > 32 {
      utf8Staging.removeFirst()
      inputBuffer.unicodeScalars.append("\u{FFFD}")
    }

    while !utf8Staging.isEmpty, String(bytes: utf8Staging, encoding: .utf8) == nil {
      utf8Staging.removeLast()
    }
    collapseUtfStagingToBuffer()
  }

  private func ingestUtf8Continuation(_ byte: UInt8) {
    utf8Staging.append(byte)
    collapseUtfStagingToBuffer()

    guard utf8Staging.count > 8 else { return }
    utf8Staging.removeFirst()
    inputBuffer.unicodeScalars.append("\u{FFFD}")
    collapseUtfStagingToBuffer()
  }

  /// Moves complete UTF‑8 prefixes from staging into ``inputBuffer`` (leaves leftover bytes staged).
  private func collapseUtfStagingToBuffer() {
    while String(bytes: utf8Staging, encoding: .utf8) != nil, !utf8Staging.isEmpty {
      let decoded = utf8Staging
      utf8Staging.removeAll(keepingCapacity: true)
      guard let text = String(bytes: decoded, encoding: .utf8) else { return }
      for ch in text {
        switch ch {
        case Character(UnicodeScalar(0)): continue
        case "\u{001b}", "\u{007F}", "\u{0008}":
          continue
        default:
          inputBuffer.append(ch)
        }
      }
    }
  }

  /// Bracketed paste body (`\e[200~\` … `\e[201~`): literals only; close sequence is peeled off separately.
  private func ingestBracketPasteLiteral(_ byte: UInt8) {
    ingestUtf8Continuation(byte)
  }

  /// Detects `\e[201~` terminator while emitting every other byte as pasted text (including LF/Tab).
  private func ingestBracketPasteByte(_ byte: UInt8) {
    func flushCloseFalseStart() {
      for idx in 0..<bracketCloseMatchPrefix {
        ingestBracketPasteLiteral(Self.bracketPasteCloseSeq[idx])
      }
      bracketCloseMatchPrefix = 0
    }

    if byte == Self.bracketPasteCloseSeq[bracketCloseMatchPrefix] {
      bracketCloseMatchPrefix += 1
      if bracketCloseMatchPrefix == Self.bracketPasteCloseSeq.count {
        bracketCloseMatchPrefix = 0
        bracketedPasteActive = false
        collapseUtfStagingToBuffer()
      }
      return
    }

    if bracketCloseMatchPrefix > 0 {
      flushCloseFalseStart()
      ingestBracketPasteByte(byte)
      return
    }

    ingestBracketPasteLiteral(byte)
  }

  private func handleTerminatedCSI(
    _ bytes: ContiguousArray<UInt8>,
    sink _: SlateTranscriptSink,
    gate _: UserLineGate
  ) {
    if bytes.elementsEqual(Self.bracketPasteOpenSeq) {
      utf8Staging.removeAll(keepingCapacity: true)
      bracketedPasteActive = true
      bracketCloseMatchPrefix = 0
      return
    }

    guard bytes.count >= 3, bytes[0] == 27, bytes[1] == 91 else { return }
    let terminator = bytes[bytes.count - 1]

    let paramRegion = bytes[2..<(bytes.count - 1)]
    guard let inner = String(bytes: paramRegion, encoding: .utf8) else { return }
    let ints = inner.split(separator: ";").compactMap { Int($0) }

    switch terminator {
    case UInt8(ascii: "u"):
      // CSI u — plain Enter is `\r`. Non-zero modifier = soft newline (bitmask Shift=1, Alt=2, …).
      guard let key = ints.first, key == 13 else { return }
      guard ints.count >= 2, ints[1] != 0 else { return }

    case UInt8(ascii: "~"):
      // Bracket paste open/close handled above; bracketed paste uses 200~/201~ digits.
      // xterm-style modified keys: `CSI 27 ; <modifier> ; 13 ~` (Shift+Enter often `27;2;13~`).
      if ints.count >= 3, ints[0] == 27, ints[2] == 13, ints[1] != 0 {
        break
      }
      // Alternate `CSI 13 ; <modifier> ~` forms.
      if ints.count >= 2, ints[0] == 13, ints[1] != 0 {
        break
      }
      return

    default:
      return
    }

    inputBuffer.append("\n")
    swallowLfAfterCrSubmit = false
  }
}

enum ChatTerminalError: Error, LocalizedError {
  /// Stdin is not a TTY (pipes, redirection, CI, etc.).
  case notATerminal
  /// Slate declined or could not use the alternate-screen UI.
  case slateNotInteractive

  var errorDescription: String? {
    switch self {
    case .notATerminal:
      return "`scribe chat` requires an interactive terminal (stdin must be a TTY)."
    case .slateNotInteractive:
      return "`scribe chat` requires a fully interactive terminal; the fullscreen UI could not attach."
    }
  }
}

enum SlateChat {
  /// Runs the chat session using the Slate alternate-screen UI; fails if stdin is not a TTY or Slate cannot attach.
  static func runFullscreen(
    configuration: AgentConfig,
    client: Client,
    systemPrompt: String
  ) async throws {
    guard isatty(STDIN_FILENO) != 0 else {
      configuration.makeStderrLogger().error(
        "chat: stdin is not a TTY; interactive fullscreen chat is unavailable in this environment")
      throw ChatTerminalError.notATerminal
    }
    try await Task { @MainActor () throws -> Void in
      let host = SlateChatHost(
        configuration: configuration,
        client: client,
        systemPrompt: systemPrompt)
      do {
        try await host.run()
      } catch Slate.InstallationError.notInteractiveTerminal {
        configuration.makeStderrLogger().error(
          "chat: Slate refused non-interactive terminal (InstallationError.notInteractiveTerminal)")
        throw ChatTerminalError.slateNotInteractive
      }
    }.value
  }
}
