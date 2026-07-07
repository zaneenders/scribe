import Foundation
import ScribeCore
import SlateCore

struct QueuedTrayLine: Equatable, Sendable {
  enum Kind: Equatable, Sendable {
    case firstMessage
    case additionalMessage
    case sending
    case waiting
    case nextUp
    case overflowRemaining(Int)
    case hint
  }

  var kind: Kind
  var text: String
}

internal enum SlateChatRenderer {

  private nonisolated static let llmWaitSpinner: [Character] = [
    "⣾", "⣽", "⣻", "⢿", "⡿", "⣟", "⣯", "⣷",
  ]

  private nonisolated static let inputGutterColumns = 6

  private nonisolated static let queuedTrayGutterColumns = 8

  private nonisolated static let queuedTrayMaxRows = 4

  nonisolated static func queuedMessagePreview(_ raw: String, maxWidth: Int) -> String {
    let normalized =
      raw
      .replacingOccurrences(of: "\r\n", with: "\n")
      .replacingOccurrences(of: "\n", with: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard maxWidth > 0 else { return normalized }
    guard normalized.count > maxWidth else { return normalized }
    if maxWidth == 1 { return "…" }
    return String(normalized.prefix(maxWidth - 1)) + "…"
  }

  nonisolated static func queuedTrayVisualLines(
    snapshot: QueuedTraySnapshot,
    textWidth: Int
  ) -> [QueuedTrayLine] {
    guard textWidth > 0 else { return [] }

    if let active = snapshot.activeDispatch {
      return buildDispatchTrayLines(snapshot: snapshot, active: active, textWidth: textWidth)
    }

    if snapshot.modelBusy, !snapshot.pending.isEmpty, snapshot.batchTotal > 0 {
      return buildAutoDrainTrayLines(snapshot: snapshot, textWidth: textWidth)
    }

    let pending = snapshot.pending
    guard !pending.isEmpty else { return [] }

    if pending.count == 1 {
      return singleMessageTrayLines(pending[0], textWidth: textWidth)
    }

    return multiMessageTrayLines(
      pending, textWidth: textWidth, modelBusy: snapshot.modelBusy)
  }

  private nonisolated static func buildDispatchTrayLines(
    snapshot: QueuedTraySnapshot,
    active: QueuedTraySnapshot.ActiveDispatch,
    textWidth: Int
  ) -> [QueuedTrayLine] {
    var lines: [QueuedTrayLine] = []
    let total = max(snapshot.batchTotal, active.index + snapshot.pending.count)
    let sendLabel = "[\(active.index)/\(total)] "
    let sendPreview = queuedMessagePreview(
      active.text, maxWidth: max(1, textWidth - sendLabel.count))
    lines.append(QueuedTrayLine(kind: .sending, text: sendLabel + sendPreview))

    var hidden = 0
    for (offset, raw) in snapshot.pending.enumerated() {
      let index = active.index + 1 + offset
      if lines.count >= queuedTrayMaxRows {
        hidden = total - index + 1
        break
      }
      if lines.count == queuedTrayMaxRows - 1, index < total {
        hidden = total - index
        break
      }
      let label = "[\(index)/\(total)] "
      let preview = queuedMessagePreview(raw, maxWidth: max(1, textWidth - label.count))
      lines.append(QueuedTrayLine(kind: .waiting, text: label + preview))
    }

    if hidden > 0, lines.count < queuedTrayMaxRows {
      lines.append(QueuedTrayLine(kind: .overflowRemaining(hidden), text: ""))
    }
    return lines
  }

  private nonisolated static func buildAutoDrainTrayLines(
    snapshot: QueuedTraySnapshot,
    textWidth: Int
  ) -> [QueuedTrayLine] {
    let total = snapshot.batchTotal
    let dispatched = total - snapshot.pending.count
    var lines: [QueuedTrayLine] = []
    var hidden = 0

    for (offset, raw) in snapshot.pending.enumerated() {
      let index = dispatched + 1 + offset
      if lines.count >= queuedTrayMaxRows {
        hidden = total - index + 1
        break
      }
      if lines.count == queuedTrayMaxRows - 1, index < total {
        hidden = total - index
        break
      }
      let label = "[\(index)/\(total)] "
      let preview = queuedMessagePreview(raw, maxWidth: max(1, textWidth - label.count))
      let kind: QueuedTrayLine.Kind = offset == 0 ? .nextUp : .waiting
      lines.append(QueuedTrayLine(kind: kind, text: label + preview))
    }

    if hidden > 0, lines.count < queuedTrayMaxRows {
      lines.append(QueuedTrayLine(kind: .overflowRemaining(hidden), text: ""))
    } else if lines.count < queuedTrayMaxRows, snapshot.pending.count > 1 {
      lines.append(
        QueuedTrayLine(
          kind: .hint,
          text: "after each turn · Ctrl+C recalls oldest"))
    }
    return lines
  }

  private nonisolated static func singleMessageTrayLines(
    _ raw: String,
    textWidth: Int
  ) -> [QueuedTrayLine] {
    let normalized = raw.replacingOccurrences(of: "\r\n", with: "\n")
    let wrapped = TranscriptLayout.inputVisualLines(from: normalized, textWidth: textWidth)
    let capped: [String]
    if wrapped.count <= queuedTrayMaxRows {
      capped = wrapped
    } else {
      var lines = Array(wrapped.prefix(queuedTrayMaxRows))
      if !lines.isEmpty {
        var last = lines[lines.count - 1]
        if last.count > 1 {
          last = String(last.prefix(max(1, last.count - 1))) + "…"
        } else {
          last = "…"
        }
        lines[lines.count - 1] = last
      }
      capped = lines
    }
    return capped.enumerated().map { index, line in
      QueuedTrayLine(
        kind: index == 0 ? .firstMessage : .additionalMessage,
        text: line)
    }
  }

  private nonisolated static func multiMessageTrayLines(
    _ pending: [String],
    textWidth: Int,
    modelBusy: Bool
  ) -> [QueuedTrayLine] {
    var lines: [QueuedTrayLine] = []
    let total = pending.count
    var hidden = 0

    for (index, raw) in pending.enumerated() {
      let label = "[\(index + 1)/\(total)] "
      let labelWidth = label.count
      let preview = queuedMessagePreview(raw, maxWidth: max(1, textWidth - labelWidth))
      let rowText = label + preview

      if lines.count >= queuedTrayMaxRows {
        hidden = total - index
        break
      }
      if lines.count == queuedTrayMaxRows - 1, index < total - 1 {
        hidden = total - index
        break
      }

      lines.append(
        QueuedTrayLine(
          kind: index == 0 ? .firstMessage : .additionalMessage,
          text: rowText))
    }

    if hidden > 0, lines.count < queuedTrayMaxRows {
      lines.append(QueuedTrayLine(kind: .overflowRemaining(hidden), text: ""))
    } else if lines.count < queuedTrayMaxRows, modelBusy {
      lines.append(
        QueuedTrayLine(kind: .hint, text: "Enter → interrupt · flush queue"))
    }
    return lines
  }

  nonisolated static func queuedTrayVisualLines(
    queuedMessages: [String],
    textWidth: Int
  ) -> [QueuedTrayLine] {
    queuedTrayVisualLines(
      snapshot: QueuedTraySnapshot(pending: queuedMessages),
      textWidth: textWidth)
  }

  nonisolated static func queuedTrayRowCount(
    snapshot: QueuedTraySnapshot,
    cols: Int
  ) -> Int {
    let textWidth = max(0, cols &- queuedTrayGutterColumns)
    return queuedTrayVisualLines(snapshot: snapshot, textWidth: textWidth).count
  }

  nonisolated static func queuedTrayRowCount(
    queuedMessages: [String],
    cols: Int
  ) -> Int {
    queuedTrayRowCount(
      snapshot: QueuedTraySnapshot(pending: queuedMessages),
      cols: cols)
  }

  nonisolated static func transcriptContentRows(
    cols: Int,
    rows: Int,
    banner: BannerSnapshot?,
    usage: UsageHUDSnapshot?,
    inputLine: String,
    waitingForLLM: Bool,
    queuedTraySnapshot: QueuedTraySnapshot
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

    let trayRowCount = queuedTrayRowCount(snapshot: queuedTraySnapshot, cols: cols)
    let firstInputRow = rows &- inputRowCount
    let firstTrayRow = max(headerRows, firstInputRow &- trayRowCount)
    return max(0, firstTrayRow &- headerRows)
  }

  nonisolated static func buildGrid(
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
    queuedTraySnapshot: QueuedTraySnapshot,
    picker: PickerSnapshot? = nil,
    profilePicker: ProfilePickerSnapshot? = nil,
    theme: CLITheme
  ) -> [[StyledSpan]] {
    let transcriptFill = StyledSpan(fg: theme.inputText, bg: theme.background, bold: false, text: " ")
    let inputFill = StyledSpan(fg: theme.inputText, bg: theme.inputAreaBg, bold: false, text: " ")

    var grid = [[StyledSpan]](
      repeating: [StyledSpan](repeating: transcriptFill, count: cols),
      count: rows
    )

    let headerRows: Int = {
      if banner != nil { return min(3, max(0, rows &- 1)) }
      if usage != nil, rows >= 2 { return min(3, max(1, rows &- 1)) }
      return 0
    }()

    let contentRows = transcriptContentRows(
      cols: cols, rows: rows, banner: banner, usage: usage,
      inputLine: inputLine, waitingForLLM: waitingForLLM,
      queuedTraySnapshot: queuedTraySnapshot)

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
      let needsExtraCursorRow = lines.last.map { $0.count >= textWidth && textWidth > 0 } ?? false
      if needsExtraCursorRow { lines.append("") }
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
      snapshot: queuedTraySnapshot, textWidth: trayTextWidth)
    let availableTrayRows = max(0, firstInputRow &- headerRows)
    let trayVisualLines = Array(rawTrayLines.prefix(availableTrayRows))
    let trayRowCount = trayVisualLines.count
    let firstTrayRow = max(headerRows, firstInputRow &- trayRowCount)

    let inputBgRowCount = trayRowCount &+ inputRowCount
    if inputBgRowCount > 0 {
      fillSemanticRect(
        &grid, col: 0, row: firstTrayRow,
        width: cols, height: inputBgRowCount, with: inputFill)
    }

    let usageReserve: Int = {
      guard let u = usage else { return 0 }
      let w = usageHUDSemanticCharCount(u, maxRows: headerRows, theme: theme)
      return min(cols, w &+ 1)
    }()
    let bannerMaxWithUsage = usageReserve > 0 ? max(0, cols &- usageReserve) : cols

    if headerRows >= 1 {
      if let banner {
        buildSemanticBannerKV(
          &grid, row: 0, cols: cols, maxWidth: bannerMaxWithUsage,
          label: "LLM: ",
          valueSpans: [
            StyledSpan(
              fg: theme.bannerValue, bg: theme.background,
              bold: false, text: banner.baseURL)
          ],
          theme: theme)
      }
      if let u = usage {
        buildSemanticUsageHUD(&grid, cols: cols, usage: u, maxRows: headerRows, theme: theme)
      }
    }

    if headerRows >= 2, let banner {
      let shortId = String(banner.sessionId.prefix(8))
      let modelWithVersion =
        "[\(banner.profileName)] \(banner.model)  v:\(banner.scribeVersion)  sid:\(shortId)"
      buildSemanticBannerKV(
        &grid, row: 1, cols: cols, maxWidth: bannerMaxWithUsage,
        label: "Model: ",
        valueSpans: [
          StyledSpan(
            fg: theme.bannerValue, bg: theme.background,
            bold: false, text: modelWithVersion)
        ],
        theme: theme)
    }

    if headerRows >= 3, let banner {
      let bg = theme.background
      var cwdSpans: [StyledSpan] = [
        StyledSpan(fg: theme.bannerValue, bg: bg, bold: false, text: banner.cwd)
      ]
      if let branch = banner.gitBranch {
        cwdSpans.append(
          StyledSpan(fg: theme.bannerLabel, bg: bg, bold: false, text: "@\(branch)"))
      }
      buildSemanticBannerKV(
        &grid, row: 2, cols: cols, maxWidth: bannerMaxWithUsage,
        label: "CWD: ", valueSpans: cwdSpans, theme: theme)
    }

    if contentRows > 0 {
      let flat = flattenedTranscript
      let maxTailStart = max(0, flat.count &- contentRows)
      let tailStart = min(max(0, transcriptTailStart), maxTailStart)
      let visibleCount = min(contentRows, flat.count &- tailStart)
      let topPad = contentRows &- visibleCount
      var y = headerRows &+ topPad
      var idx = tailStart
      let endIdx = tailStart &+ visibleCount
      while idx < endIdx {
        guard y < firstTrayRow else { break }
        writeSemanticSpans(&grid, col: 0, row: y, maxWidth: cols, spans: flat[idx].spans)
        y &+= 1
        idx &+= 1
      }
    }

    if trayRowCount > 0 {
      buildSemanticQueuedTrayRows(
        &grid, startRow: firstTrayRow, cols: cols,
        textWidth: trayTextWidth, visualLines: trayVisualLines, theme: theme)
    }

    if let profilePicker {
      buildSemanticProfilePickerRows(
        &grid, startRow: firstInputRow, cols: cols,
        rowCount: min(2, inputRowCount), picker: profilePicker, theme: theme)
    } else if let picker {
      buildSemanticPickerRows(
        &grid, startRow: firstInputRow, cols: cols,
        rowCount: inputRowCount, picker: picker, theme: theme)
    } else {
      buildSemanticInputRows(
        &grid, startRow: firstInputRow, cols: cols,
        textWidth: textWidth, visualLines: visualLines, rowCount: inputRowCount,
        inputMode: inputMode,
        llmWaitAnimationFrame: llmWaitAnimationFrame, waitingForLLM: waitingForLLM,
        theme: theme)
    }

    return grid
  }

  nonisolated static func buildSemanticProfilePickerRows(
    _ grid: inout [[StyledSpan]],
    startRow: Int, cols: Int, rowCount: Int,
    picker: ProfilePickerSnapshot,
    theme: CLITheme
  ) {
    guard rowCount >= 1, cols > 0 else { return }
    let bg = theme.inputAreaBg
    let labelColor = theme.userPrefix
    let normalFG = theme.inputText
    let hintFG = theme.inputGutter
    let activeFG = theme.warningFG

    let profile = picker.currentProfile
    let position = "\(picker.cursor + 1)/\(picker.profileCount)"
    let marker = profile.name == picker.activeName ? "▸ " : "  "
    let hint = "   ↑↓ move · Enter select · Esc cancel"

    let row0 = startRow
    if row0 >= 0, row0 < grid.count {
      let spans: [StyledSpan] = [
        StyledSpan(fg: labelColor, bg: bg, bold: true, text: "[MODEL] "),
        StyledSpan(fg: hintFG, bg: bg, bold: false, text: position + " "),
        StyledSpan(
          fg: profile.name == picker.activeName ? activeFG : normalFG,
          bg: bg,
          bold: profile.name == picker.activeName,
          text: marker + profile.name),
        StyledSpan(fg: hintFG, bg: bg, bold: false, text: hint),
      ]
      writeSemanticSpans(&grid, col: 0, row: row0, maxWidth: cols, spans: spans)
    }

    guard rowCount >= 2 else { return }
    let row1 = startRow + 1
    if row1 >= 0, row1 < grid.count {
      let detail = "\(profile.model) · \(profile.baseURL)"
      let spans: [StyledSpan] = [
        StyledSpan(fg: hintFG, bg: bg, bold: false, text: "        "),
        StyledSpan(fg: normalFG, bg: bg, bold: false, text: detail),
      ]
      writeSemanticSpans(&grid, col: 0, row: row1, maxWidth: cols, spans: spans)
    }
  }

  nonisolated static func buildSemanticPickerRows(
    _ grid: inout [[StyledSpan]],
    startRow: Int, cols: Int, rowCount: Int,
    picker: PickerSnapshot,
    theme: CLITheme
  ) {
    guard rowCount >= 1, cols > 0 else { return }
    let bg = theme.inputAreaBg
    let labelColor = theme.userPrefix
    let normalFG = theme.inputText
    let hintFG = theme.inputGutter
    let activeFG = theme.warningFG

    let row0 = startRow
    if row0 >= 0, row0 < grid.count {
      var spans: [StyledSpan] = []
      switch picker.kind {
      case .fork:
        let position = "msg \(picker.currentBoundary) / \(picker.messageCount)"
        let hint = "   ↑↓ change · Enter confirm · Esc cancel"
        spans = [
          StyledSpan(fg: labelColor, bg: bg, bold: true, text: "[FORK] "),
          StyledSpan(fg: normalFG, bg: bg, bold: false, text: position),
          StyledSpan(fg: hintFG, bg: bg, bold: false, text: hint),
        ]
      case .tldr:
        let startActive = !picker.activeIsEnd
        let endActive = picker.activeIsEnd
        let hint = "   ↑↓ move · Tab switch · Enter confirm · Esc cancel"
        spans = [
          StyledSpan(fg: labelColor, bg: bg, bold: true, text: "[TLDR] "),
          StyledSpan(fg: normalFG, bg: bg, bold: false, text: "start "),
          StyledSpan(
            fg: startActive ? activeFG : normalFG, bg: bg, bold: startActive,
            text: "\(picker.startBoundary)"),
          StyledSpan(fg: normalFG, bg: bg, bold: false, text: " · end "),
          StyledSpan(
            fg: endActive ? activeFG : normalFG, bg: bg, bold: endActive,
            text: "\(picker.endBoundary)"),
          StyledSpan(fg: normalFG, bg: bg, bold: false, text: " of \(picker.messageCount)"),
          StyledSpan(fg: hintFG, bg: bg, bold: false, text: hint),
        ]
      }
      writeSemanticSpans(&grid, col: 0, row: row0, maxWidth: cols, spans: spans)
    }

    guard rowCount >= 2 else { return }
    let row1 = startRow + 1
    if row1 >= 0, row1 < grid.count {
      let prefix: String = {
        switch picker.kind {
        case .fork: return "next: "
        case .tldr:
          return picker.activeIsEnd ? "first preserved: " : "first to collapse: "
        }
      }()
      let spans: [StyledSpan] = [
        StyledSpan(fg: hintFG, bg: bg, bold: false, text: prefix),
        StyledSpan(fg: normalFG, bg: bg, bold: false, text: picker.previewText),
      ]
      writeSemanticSpans(&grid, col: 0, row: row1, maxWidth: cols, spans: spans)
    }
  }

  private nonisolated static func fillSemanticRect(
    _ grid: inout [[StyledSpan]],
    col col0: Int, row row0: Int,
    width: Int, height: Int,
    with span: StyledSpan
  ) {
    let c0 = max(0, col0)
    let c1 = min(col0 &+ width, grid[0].count)
    let r0 = max(0, row0)
    let r1 = min(row0 &+ height, grid.count)
    guard c1 > c0, r1 > r0 else { return }
    for r in r0..<r1 {
      for c in c0..<c1 {
        grid[r][c] = span
      }
    }
  }

  private nonisolated static func writeSemanticSpans(
    _ grid: inout [[StyledSpan]],
    col col0: Int, row: Int, maxWidth: Int,
    spans: [StyledSpan]
  ) {
    guard row >= 0, row < grid.count, col0 >= 0, col0 < grid[0].count, maxWidth > 0 else { return }
    let endCol = min(col0 &+ maxWidth, grid[0].count)
    var x = col0
    for span in spans {
      guard x < endCol else { break }
      for ch in span.text {
        guard x < endCol else { break }
        grid[row][x] = StyledSpan(fg: span.fg, bg: span.bg, bold: span.bold, text: String(ch))
        x &+= 1
      }
    }
  }

  private nonisolated static func buildSemanticBannerKV(
    _ grid: inout [[StyledSpan]],
    row: Int, cols: Int, maxWidth: Int,
    label: String,
    valueSpans: [StyledSpan],
    theme: CLITheme
  ) {
    guard row >= 0, row < grid.count, !valueSpans.isEmpty else { return }
    let bg = theme.background
    let cap = min(max(0, maxWidth), cols)
    let maxValueChars = max(0, cap &- label.count)

    var spans = valueSpans
    let totalChars = spans.reduce(0) { $0 + $1.text.count }
    if totalChars > maxValueChars {
      var budget = maxValueChars
      var trimmed: [StyledSpan] = []
      for span in spans {
        guard budget > 0 else { break }
        if span.text.count <= budget {
          trimmed.append(span)
          budget -= span.text.count
        } else {
          trimmed.append(
            StyledSpan(
              fg: span.fg, bg: span.bg, bold: span.bold,
              text: String(span.text.prefix(max(0, budget &- 1))) + "…"))
          budget = 0
        }
      }
      spans = trimmed
    }

    var allSpans = spans
    allSpans.insert(
      StyledSpan(fg: theme.bannerLabel, bg: bg, bold: false, text: label), at: 0)
    writeSemanticSpans(&grid, col: 0, row: row, maxWidth: cap, spans: allSpans)
  }

  private nonisolated static func buildSemanticUsageHUD(
    _ grid: inout [[StyledSpan]],
    cols: Int,
    usage: UsageHUDSnapshot?,
    maxRows: Int,
    theme: CLITheme
  ) {
    guard let usage, maxRows > 0 else { return }
    let lines = usageHUDSemanticSpans(from: usage, maxRows: maxRows, theme: theme)
    for (rowOffset, spans) in lines.enumerated() {
      guard rowOffset < maxRows else { break }
      let w = spans.reduce(0) { $0 + $1.text.count }
      let startCol = max(0, cols &- w)
      writeSemanticSpans(
        &grid, col: startCol, row: rowOffset,
        maxWidth: cols &- startCol, spans: spans)
    }
  }

  nonisolated static func buildSemanticInputRows(
    _ grid: inout [[StyledSpan]],
    startRow: Int, cols: Int, textWidth: Int,
    visualLines: [String], rowCount: Int,
    inputMode: EditMode = .edit,
    llmWaitAnimationFrame: Int, waitingForLLM: Bool,
    theme: CLITheme
  ) {
    let bg = theme.inputAreaBg
    let gutter = String(repeating: " ", count: min(inputGutterColumns, cols))

    let modeLabel = inputMode == .edit ? "EDIT: " : "READ: "
    let modeColor = inputMode == .edit ? theme.userPrefix : theme.scribePrefix
    let showSpinner = waitingForLLM && visualLines.isEmpty
    var lineIdx = 0
    while lineIdx < rowCount {
      let row = startRow &+ lineIdx
      guard row >= 0, row < grid.count else { break }
      let onLastInputRow = lineIdx == rowCount &- 1

      var spans: [StyledSpan] = []
      if showSpinner, onLastInputRow {
        spans.append(StyledSpan(fg: modeColor, bg: bg, bold: false, text: modeLabel))
        let frames = llmWaitSpinner
        let ch = frames[llmWaitAnimationFrame % frames.count]
        spans.append(StyledSpan(fg: theme.spinnerGlyph, bg: bg, bold: false, text: String(ch)))
        spans.append(StyledSpan(fg: theme.inputCursor, bg: bg, bold: false, text: "▏"))
      } else if lineIdx == 0 {
        if waitingForLLM {
          let frames = llmWaitSpinner
          let ch = frames[llmWaitAnimationFrame % frames.count]
          spans.append(StyledSpan(fg: theme.spinnerGlyph, bg: bg, bold: false, text: String(ch)))
          spans.append(StyledSpan(fg: modeColor, bg: bg, bold: false, text: modeLabel))
        } else {
          spans.append(StyledSpan(fg: modeColor, bg: bg, bold: false, text: modeLabel))
        }
        if lineIdx < visualLines.count, textWidth > 0 {
          spans.append(
            StyledSpan(
              fg: theme.inputText, bg: bg, bold: false,
              text: String(visualLines[lineIdx].prefix(textWidth))))
        }
        if onLastInputRow {
          spans.append(StyledSpan(fg: theme.inputCursor, bg: bg, bold: false, text: "▏"))
        }
      } else {
        spans.append(StyledSpan(fg: theme.inputGutter, bg: bg, bold: false, text: gutter))
        if lineIdx < visualLines.count, textWidth > 0 {
          spans.append(
            StyledSpan(
              fg: theme.inputText, bg: bg, bold: false,
              text: String(visualLines[lineIdx].prefix(textWidth))))
        }
        if onLastInputRow {
          spans.append(StyledSpan(fg: theme.inputCursor, bg: bg, bold: false, text: "▏"))
        }
      }
      writeSemanticSpans(&grid, col: 0, row: row, maxWidth: cols, spans: spans)
      lineIdx &+= 1
    }
  }

  nonisolated static func buildSemanticQueuedTrayRows(
    _ grid: inout [[StyledSpan]],
    startRow: Int, cols: Int, textWidth: Int,
    visualLines: [QueuedTrayLine],
    theme: CLITheme
  ) {
    guard !visualLines.isEmpty else { return }
    let bg = theme.inputAreaBg
    let gutterText = String(repeating: " ", count: min(queuedTrayGutterColumns, cols))
    var lineIdx = 0
    while lineIdx < visualLines.count {
      let row = startRow &+ lineIdx
      guard row >= 0, row < grid.count else { break }

      let trayLine = visualLines[lineIdx]
      var spans: [StyledSpan] = []
      switch trayLine.kind {
      case .firstMessage:
        spans.append(StyledSpan(fg: theme.queuedPrefix, bg: bg, bold: false, text: "queued: "))
        if textWidth > 0 {
          spans.append(
            StyledSpan(
              fg: theme.queuedText, bg: bg, bold: false,
              text: String(trayLine.text.prefix(textWidth))))
        }
      case .sending:
        spans.append(StyledSpan(fg: theme.queuedPrefix, bg: bg, bold: false, text: "send:   "))
        if textWidth > 0 {
          spans.append(
            StyledSpan(
              fg: theme.userPrefix, bg: bg, bold: false,
              text: String(trayLine.text.prefix(textWidth))))
        }
      case .nextUp:
        spans.append(StyledSpan(fg: theme.queuedPrefix, bg: bg, bold: false, text: "next:   "))
        if textWidth > 0 {
          spans.append(
            StyledSpan(
              fg: theme.queuedText, bg: bg, bold: false,
              text: String(trayLine.text.prefix(textWidth))))
        }
      case .additionalMessage, .waiting:
        spans.append(StyledSpan(fg: theme.queuedGutter, bg: bg, bold: false, text: gutterText))
        if textWidth > 0 {
          spans.append(
            StyledSpan(
              fg: theme.queuedText, bg: bg, bold: false,
              text: String(trayLine.text.prefix(textWidth))))
        }
      case .hint:
        spans.append(StyledSpan(fg: theme.queuedGutter, bg: bg, bold: false, text: gutterText))
        if textWidth > 0 {
          spans.append(
            StyledSpan(
              fg: theme.queuedGutter, bg: bg, bold: false,
              text: String(trayLine.text.prefix(textWidth))))
        }
      case .overflowRemaining(let count):
        spans.append(StyledSpan(fg: theme.queuedGutter, bg: bg, bold: false, text: gutterText))
        if textWidth > 0 {
          spans.append(
            StyledSpan(
              fg: theme.queuedPrefix, bg: bg, bold: false,
              text: String("+\(count) more queued".prefix(textWidth))))
        }
      }
      writeSemanticSpans(&grid, col: 0, row: row, maxWidth: cols, spans: spans)
      lineIdx &+= 1
    }
  }

  private nonisolated static func semanticHudSpan(
    _ fg: TerminalRGB, _ text: String, bg: TerminalRGB, bold: Bool = false
  ) -> StyledSpan {
    StyledSpan(fg: fg, bg: bg, bold: bold, text: text)
  }

  private nonisolated static func usageHUDSemanticSpans(
    from usage: UsageHUDSnapshot, maxRows: Int, theme: CLITheme
  ) -> [[StyledSpan]] {
    let sep = "  ·  "
    let bg = theme.background

    var row0: [StyledSpan] = [
      semanticHudSpan(theme.usageLabel, "in ", bg: bg),
      semanticHudSpan(theme.usagePrompt, formatUsageIntOpt(usage.roundPrompt), bg: bg),
      semanticHudSpan(theme.usageMuted, sep, bg: bg),
      semanticHudSpan(theme.usageLabel, "out ", bg: bg),
      semanticHudSpan(theme.usageCompletion, formatUsageIntOpt(usage.roundCompletion), bg: bg),
    ]
    if let tps = usage.outputTokensPerSecond {
      row0.append(semanticHudSpan(theme.usageMuted, sep, bg: bg))
      row0.append(semanticHudSpan(theme.usageLabel, "rate ", bg: bg))
      row0.append(semanticHudSpan(theme.usageRate, String(format: "%.1f/s", tps), bg: bg))
    }
    if let pct = usage.contextWindowUsedPercent {
      row0.append(semanticHudSpan(theme.usageMuted, sep, bg: bg))
      row0.append(semanticHudSpan(theme.usageLabel, "ctx ", bg: bg))
      let pctColor: TerminalRGB =
        pct >= 90
        ? theme.usageCtxPctDanger
        : (pct >= 75 ? theme.usageCtxPctWarn : theme.usageCtxPctNormal)
      row0.append(semanticHudSpan(pctColor, "\(pct)%", bg: bg))
    }

    let hasR = (usage.reasoningTokens ?? 0) > 0
    let hasCache = (usage.cachedPromptTokens ?? 0) > 0
    let lineDetail: [StyledSpan]? = {
      guard hasR || hasCache else { return nil }
      var row1: [StyledSpan] = []
      if hasR {
        row1.append(semanticHudSpan(theme.usageLabel, "reasoning ", bg: bg))
        row1.append(semanticHudSpan(theme.usageReasoning, formatUsageInt(usage.reasoningTokens!), bg: bg))
      }
      if hasR && hasCache {
        row1.append(semanticHudSpan(theme.usageMuted, sep, bg: bg))
      }
      if hasCache {
        row1.append(semanticHudSpan(theme.usageLabel, "cache ", bg: bg))
        row1.append(semanticHudSpan(theme.usageCache, formatUsageInt(usage.cachedPromptTokens!), bg: bg))
      }
      return row1
    }()

    let lineSums: [StyledSpan] = [
      semanticHudSpan(theme.usageLabel, "turn Σ ", bg: bg),
      semanticHudSpan(theme.usageTurnSum, formatUsageInt(usage.turnTotal), bg: bg, bold: true),
      semanticHudSpan(theme.usageMuted, sep, bg: bg),
      semanticHudSpan(theme.usageLabel, "all Σ ", bg: bg),
      semanticHudSpan(theme.usageSessionSum, formatUsageInt(usage.sessionTotal), bg: bg, bold: true),
    ]

    var full: [[StyledSpan]] = [row0]
    if let lineDetail { full.append(lineDetail) }
    full.append(lineSums)

    guard maxRows > 0 else { return [] }
    if full.count <= maxRows { return full }
    if maxRows == 1 { return [row0] }
    if maxRows == 2, full.count == 3 { return [row0, lineSums] }
    return Array(full.prefix(maxRows))
  }

  private nonisolated static func usageHUDSemanticCharCount(
    _ usage: UsageHUDSnapshot, maxRows: Int, theme: CLITheme
  ) -> Int {
    usageHUDSemanticSpans(from: usage, maxRows: maxRows, theme: theme)
      .map { $0.reduce(0) { $0 + $1.text.count } }.max() ?? 0
  }

  private nonisolated static func formatUsageInt(_ n: Int) -> String {
    ScribeUsageFormatting.groupingInt(n)
  }

  private nonisolated static func formatUsageIntOpt(_ n: Int?) -> String {
    guard let n else { return "—" }
    return formatUsageInt(n)
  }

}

extension TerminalCell {

  init(span: StyledSpan) {
    self.init(
      glyph: span.text.first ?? " ",
      foreground: span.fg,
      background: span.bg,
      flags: span.bold ? .bold : []
    )
  }
}
