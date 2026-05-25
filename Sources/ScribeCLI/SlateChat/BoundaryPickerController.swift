import Foundation
import Logging
import ScribeCore
import SlateCore
import SystemPackage

@MainActor
internal final class BoundaryPickerController {

  private(set) var picker: PickerSnapshot?

  private var pickerActionTask: Task<Void, Never>?

  private var pickerBackup: (lines: [TLine], generation: Int, viewport: TranscriptViewport)?

  private var pickerMessages: [ScribeMessage] = []

  private var pickerBaseLines: [TLine] = []

  private var pickerBaseStarts: [Int] = []

  private(set) var dividerLogicalLine: Int = 0

  var scrollDirty: Bool = false

  var backupForRestore: (lines: [TLine], generation: Int, viewport: TranscriptViewport)? {
    pickerBackup
  }

  weak var host: (any BoundaryPickerHost)?
  var configuration: ScribeConfig = ScribeConfig(
    agentModel: "", contextWindow: 0, contextWindowThreshold: 0,
    serverURL: "", apiKey: nil, workingDirectory: ".", reasoningEnabled: false)
  var logger: Logger = Logger(label: "scribe.picker.unset")
  var theme: CLITheme = .default
  var markdownRenderer: MarkdownRenderer = SwiftMarkdownRenderer()

  func handleInput(
    _ action: TerminalInputAction,
    transcriptState: inout TranscriptState,
    viewport: inout TranscriptViewport,
    flattenCache: inout TranscriptLayout.FlattenCache
  ) -> Bool {
    switch action {
    case .arrowUp:
      moveCursor(by: -1, transcriptState: &transcriptState, flattenCache: &flattenCache)
    case .arrowDown:
      moveCursor(by: +1, transcriptState: &transcriptState, flattenCache: &flattenCache)
    case .tab:
      toggleActive(transcriptState: &transcriptState, flattenCache: &flattenCache)
    case .enter:
      confirm(transcriptState: &transcriptState, viewport: &viewport, flattenCache: &flattenCache)
    case .escape, .ctrlC:
      cancel(transcriptState: &transcriptState, viewport: &viewport, flattenCache: &flattenCache)
    default:
      return false
    }
    return true
  }

  func open(
    kind: PickerSnapshot.Kind,
    snapshot: SessionDocumentSnapshot,
    modelBusy: Bool,
    transcriptState: inout TranscriptState,
    viewport: inout TranscriptViewport,
    flattenCache: inout TranscriptLayout.FlattenCache
  ) -> Bool {

    if modelBusy {
      logger.notice(
        "chat.picker.open.skip",
        metadata: ["kind": "\(kind)", "reason": "model-busy"])
      return false
    }
    let boundaries = snapshot.safeForkBoundaries
    switch kind {
    case .fork:
      guard !boundaries.isEmpty else {
        logger.notice(
          "chat.picker.open.skip",
          metadata: ["kind": "fork", "reason": "no-safe-boundary"])
        return false
      }
    case .tldr:
      guard boundaries.count >= 2 else {
        logger.notice(
          "chat.picker.open.skip",
          metadata: ["kind": "tldr", "reason": "needs-two-boundaries"])
        return false
      }
    }
    let (startC, endC) = Self.defaultCursor(
      kind: kind, messages: snapshot.messages, boundaries: boundaries)
    let snap = PickerSnapshot(
      kind: kind,
      boundaries: boundaries,
      startCursor: startC,
      endCursor: endC,
      activeIsEnd: false,
      messageCount: snapshot.count,
      previewText: Self.pickerPreview(for: snapshot.messages, at: boundaries[startC]))

    let rendered = renderMessagesToTranscriptWithStarts(
      snapshot.messages, theme: theme, renderer: markdownRenderer)
    self.pickerMessages = snapshot.messages
    self.pickerBaseLines = rendered.lines
    self.pickerBaseStarts = rendered.messageStartLines
    self.pickerBackup = (transcriptState.lines, transcriptState.generation, viewport)

    applyPickerView(snapshot: snap, transcriptState: &transcriptState, flattenCache: &flattenCache)
    logger.debug(
      "chat.picker.open",
      metadata: [
        "kind": "\(kind)",
        "boundaries": "\(boundaries.count)",
        "default_start": "\(boundaries[startC])",
        "default_end": "\(endC.map { "\(boundaries[$0])" } ?? "nil")",
      ])
    return true
  }

  func cancel(
    transcriptState: inout TranscriptState,
    viewport: inout TranscriptViewport,
    flattenCache: inout TranscriptLayout.FlattenCache
  ) {
    guard picker != nil else { return }
    picker = nil
    restoreFromBackup(
      transcriptState: &transcriptState, viewport: &viewport, flattenCache: &flattenCache)
    logger.debug("chat.picker.cancel")
    host?.requestRender()
  }

  func cancelTask() {
    pickerActionTask?.cancel()
    pickerActionTask = nil
  }

  func clear() {
    picker = nil
    pickerActionTask?.cancel()
    pickerActionTask = nil
    pickerBackup = nil
    pickerMessages = []
    pickerBaseLines = []
    pickerBaseStarts = []
    dividerLogicalLine = 0
    scrollDirty = false
  }

  private func moveCursor(
    by delta: Int,
    transcriptState: inout TranscriptState,
    flattenCache: inout TranscriptLayout.FlattenCache
  ) {
    guard var snap = picker else { return }
    let activeCurrent =
      snap.activeIsEnd ? (snap.endCursor ?? snap.startCursor) : snap.startCursor
    var newCursor = max(0, min(snap.boundaries.count - 1, activeCurrent + delta))
    if snap.kind == .tldr, let endIdx = snap.endCursor {
      if snap.activeIsEnd {
        newCursor = max(newCursor, snap.startCursor + 1)
      } else {
        newCursor = min(newCursor, endIdx - 1)
      }
      newCursor = max(0, min(snap.boundaries.count - 1, newCursor))
    }
    if newCursor == activeCurrent { return }
    if snap.activeIsEnd {
      snap.endCursor = newCursor
    } else {
      snap.startCursor = newCursor
    }
    snap.previewText = Self.pickerPreview(
      for: pickerMessages, at: snap.boundaries[newCursor])
    applyPickerView(snapshot: snap, transcriptState: &transcriptState, flattenCache: &flattenCache)
  }

  private func toggleActive(
    transcriptState: inout TranscriptState,
    flattenCache: inout TranscriptLayout.FlattenCache
  ) {
    guard var snap = picker, snap.kind == .tldr, snap.endCursor != nil else { return }
    snap.activeIsEnd.toggle()
    let activeCursor =
      snap.activeIsEnd ? (snap.endCursor ?? snap.startCursor) : snap.startCursor
    snap.previewText = Self.pickerPreview(
      for: pickerMessages, at: snap.boundaries[activeCursor])
    applyPickerView(snapshot: snap, transcriptState: &transcriptState, flattenCache: &flattenCache)
  }

  private func confirm(
    transcriptState: inout TranscriptState,
    viewport: inout TranscriptViewport,
    flattenCache: inout TranscriptLayout.FlattenCache
  ) {
    guard let snap = picker else { return }
    picker = nil
    scrollDirty = false
    let kind = snap.kind
    let startCut = snap.startBoundary
    let endCut = snap.endBoundary
    let configuration = self.configuration
    let logger = self.logger
    let parentSessionId = host?.sessionId ?? UUID()
    guard let harness = host?.harness else {
      logger.warning("chat.picker.confirm.skip", metadata: ["reason": "no-harness"])
      host?.setModelBusy(false)
      host?.requestRender()
      return
    }

    logger.notice(
      "chat.picker.confirm",
      metadata: [
        "kind": "\(kind)",
        "start_cut": "\(startCut)",
        "end_cut": kind == .tldr ? "\(endCut)" : "n/a",
      ])

    host?.setModelBusy(true)
    host?.requestRender()

    pickerActionTask?.cancel()
    pickerActionTask = Task { [weak self] in
      guard let self else { return }
      do {
        guard await MainActor.run(body: { self.host?.isHostActive ?? false }) else { return }

        let newId = UUID()
        switch kind {
        case .fork:
          if let change = try await harness.applyEdit(.fork(cutAt: startCut, newSessionId: newId)) {
            await MainActor.run { self.host?.handleIdentityChange(change) }
          }
          logger.notice(
            "chat.fork.create",
            metadata: [
              "parent": "\(parentSessionId.uuidString)",
              "child": "\(newId.uuidString)",
              "cut_at": "\(startCut)",
            ])
        case .tldr:
          let slice = await MainActor.run {
            Array(self.pickerMessages[startCut..<endCut])
          }
          let summary = try await SessionSummarizer.summarize(
            slice: slice, configuration: configuration, logger: logger)
          let replacement = [ScribeMessage(role: .assistant, content: summary)]
          if let change = try await harness.applyEdit(
            .forkSplice(
              startCut: startCut,
              endCut: endCut,
              replacement: replacement,
              newSessionId: newId))
          {
            await MainActor.run { self.host?.handleIdentityChange(change) }
          }
          let tailCount = max(0, pickerMessages.count - endCut)
          logger.notice(
            "chat.tldr.create",
            metadata: [
              "parent": "\(parentSessionId.uuidString)",
              "child": "\(newId.uuidString)",
              "start_cut": "\(startCut)",
              "end_cut": "\(endCut)",
              "slice_messages": "\(slice.count)",
              "tail_messages": "\(tailCount)",
              "summary_chars": "\(summary.count)",
            ])
        }

        await MainActor.run { [weak self] in
          guard let self, self.host?.isHostActive ?? false else { return }
          self.host?.setModelBusy(false)
          self.host?.requestRender()
        }
      } catch {
        if Task.isCancelled { return }
        let se = (error as? ScribeError) ?? .generic(String(describing: error))
        logger.error(
          "chat.picker.action.fail",
          metadata: ["err": "\(se.errorDescription ?? String(describing: se))"])
        await MainActor.run { [weak self] in
          guard let self, let host = self.host, host.isHostActive else { return }
          host.enqueueTranscriptEvent(.lifecycle(.error(se)))
          host.restoreTranscriptFromPickerBackup()
          self.picker = nil
          self.pickerBackup = nil
          self.pickerMessages = []
          self.pickerBaseLines = []
          self.pickerBaseStarts = []
          self.scrollDirty = false
          host.setModelBusy(false)
          host.requestRender()
        }
      }
    }
  }

  private func applyPickerView(
    snapshot: PickerSnapshot,
    transcriptState: inout TranscriptState,
    flattenCache: inout TranscriptLayout.FlattenCache
  ) {
    picker = snapshot
    let startBase =
      pickerBaseStarts.indices.contains(snapshot.startBoundary)
      ? pickerBaseStarts[snapshot.startBoundary]
      : pickerBaseLines.count
    let endBase: Int?
    if snapshot.kind == .tldr {
      let endBoundary = snapshot.endBoundary
      endBase =
        pickerBaseStarts.indices.contains(endBoundary)
        ? pickerBaseStarts[endBoundary]
        : pickerBaseLines.count
    } else {
      endBase = nil
    }
    let styled = Self.buildStyledLines(
      base: pickerBaseLines,
      startCutBase: startBase,
      endCutBase: endBase,
      kind: snapshot.kind,
      activeIsEnd: snapshot.activeIsEnd,
      theme: theme)
    transcriptState.lines = styled.lines
    transcriptState.generation &+= 1
    dividerLogicalLine = styled.dividerLine
    scrollDirty = true
    flattenCache = TranscriptLayout.FlattenCache()
    host?.requestRender()
  }

  private func restoreFromBackup(
    transcriptState: inout TranscriptState,
    viewport: inout TranscriptViewport,
    flattenCache: inout TranscriptLayout.FlattenCache
  ) {
    guard let backup = pickerBackup else { return }
    transcriptState.lines = backup.lines
    transcriptState.generation = backup.generation &+ 1
    viewport = backup.viewport
    flattenCache = TranscriptLayout.FlattenCache()
    pickerBackup = nil
    pickerMessages = []
    pickerBaseLines = []
    pickerBaseStarts = []
    scrollDirty = false
  }

  static func buildStyledLines(
    base: [TLine],
    startCutBase: Int,
    endCutBase: Int?,
    kind: PickerSnapshot.Kind,
    activeIsEnd: Bool,
    theme: CLITheme
  ) -> (lines: [TLine], dividerLine: Int) {
    let dimFG = theme.inputGutter
    switch kind {
    case .fork:
      let cut = max(0, min(startCutBase, base.count))
      let divFG = theme.errorFG
      let label = "──── /fork cut · everything below would be discarded ────"
      var out: [TLine] = []
      out.reserveCapacity(base.count &+ 3)
      out.append(contentsOf: base[0..<cut])
      out.append(TLine(spans: []))
      let dividerIndex = out.count
      out.append(
        TLine(spans: [
          StyledSpan(fg: divFG, bg: theme.background, bold: true, text: label)
        ]))
      out.append(TLine(spans: []))
      for line in base[cut..<base.count] {
        if line.spans.isEmpty {
          out.append(line)
          continue
        }
        let dimmed = line.spans.map { sp in
          StyledSpan(fg: dimFG, bg: sp.bg, bold: false, text: sp.text)
        }
        out.append(TLine(spans: dimmed))
      }
      return (out, dividerIndex)

    case .tldr:
      let endBase = endCutBase ?? base.count
      let startCut = max(0, min(startCutBase, base.count))
      let endCut = max(startCut, min(endBase, base.count))
      let activeFG = theme.warningFG
      let startFG = activeIsEnd ? dimFG : activeFG
      let endFG = activeIsEnd ? activeFG : dimFG
      let startLabel = "──── /tldr start · slice begins here ────"
      let endLabel = "──── /tldr end · slice ends here · tail preserved ────"
      var out: [TLine] = []
      out.reserveCapacity(base.count &+ 6)
      out.append(contentsOf: base[0..<startCut])
      out.append(TLine(spans: []))
      let startDividerIdx = out.count
      out.append(
        TLine(spans: [
          StyledSpan(
            fg: startFG, bg: theme.background, bold: !activeIsEnd,
            text: startLabel)
        ]))
      out.append(TLine(spans: []))
      for line in base[startCut..<endCut] {
        if line.spans.isEmpty {
          out.append(line)
          continue
        }
        let dimmed = line.spans.map { sp in
          StyledSpan(fg: dimFG, bg: sp.bg, bold: false, text: sp.text)
        }
        out.append(TLine(spans: dimmed))
      }
      out.append(TLine(spans: []))
      let endDividerIdx = out.count
      out.append(
        TLine(spans: [
          StyledSpan(
            fg: endFG, bg: theme.background, bold: activeIsEnd, text: endLabel)
        ]))
      out.append(TLine(spans: []))
      out.append(contentsOf: base[endCut..<base.count])
      let activeDivider = activeIsEnd ? endDividerIdx : startDividerIdx
      return (out, activeDivider)
    }
  }

  static func pickerPreview(for messages: [ScribeMessage], at index: Int) -> String {
    if index >= messages.count { return "<end of session>" }
    return previewText(for: messages[index])
  }

  private static func previewText(for m: ScribeMessage) -> String {
    let trimmed = m.content.trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(of: "\n", with: " ")
    let snippet: String = {
      if !trimmed.isEmpty { return String(trimmed.prefix(60)) }
      if let calls = m.toolCalls, let first = calls.first {
        return "[tool call: \(first.name)]"
      }
      return "<empty message>"
    }()
    return "\(m.role.rawValue): \(snippet)"
  }

  static func defaultCursor(
    kind: PickerSnapshot.Kind, messages: [ScribeMessage], boundaries: [Int]
  ) -> (start: Int, end: Int?) {
    guard !boundaries.isEmpty else { return (0, nil) }
    switch kind {
    case .fork:
      return (boundaries.count - 1, nil)
    case .tldr:
      let endIdx = boundaries.count - 1
      let startIdx: Int = {
        var lastUser: Int?
        for i in 0..<messages.count where messages[i].role == .user {
          lastUser = i
        }
        if let lastUser,
          let idx = boundaries.firstIndex(of: lastUser + 1),
          idx < endIdx
        {
          return idx
        }
        return max(0, endIdx - 1)
      }()
      return (startIdx, endIdx)
    }
  }
}
