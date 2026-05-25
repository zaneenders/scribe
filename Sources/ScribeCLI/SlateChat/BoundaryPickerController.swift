import Foundation
import Logging
import ScribeCore
import SlateCore
import SystemPackage


/// Owns all boundary-picker state and logic for `/fork` and `/tldr` commands.
///
/// The host (`SlateChatHost`) creates one instance at init and delegates all picker
/// input handling and lifecycle to it.  The controller reaches back to the host
/// through a small set of closures so the host remains the single source of truth
/// for session identity, model-busy flag, render wake, and hot-swap.
@MainActor
internal final class BoundaryPickerController {


  /// Active picker snapshot; `nil` when the picker is closed.
  private(set) var picker: PickerSnapshot?

  /// Running async work for a confirmed picker (e.g. summarize LLM call).
  private var pickerActionTask: Task<Void, Never>?

  /// Pre-picker transcript + viewport state so cancel can restore.
  private var pickerBackup: (lines: [TLine], generation: Int, viewport: TranscriptViewport)?

  /// Disk messages displayed by the active picker — cached to avoid re-read on cursor moves.
  private var pickerMessages: [ScribeMessage] = []

  /// Base (un-styled) transcript lines for `pickerMessages`, rebuilt on open.
  private var pickerBaseLines: [TLine] = []

  /// `messageStartLines` for `pickerBaseLines` (length `pickerMessages.count + 1`).
  private var pickerBaseStarts: [Int] = []

  /// Logical line index of the divider inside the *styled* picker transcript.
  private(set) var dividerLogicalLine: Int = 0

  /// Set on open and on every cursor move; the render closure consumes it then clears.
  var scrollDirty: Bool = false

  /// Exposed so the host can restore transcript/viewport state from the controller's backup
  /// inside a callback (where inout params are unavailable).
  var backupForRestore: (lines: [TLine], generation: Int, viewport: TranscriptViewport)? {
    pickerBackup
  }


  /// Borrow the host-owned ``SessionDocument`` long enough to read a
  /// message slice (for `/tldr` summarization). The picker doesn't get
  /// a reference to the doc itself — only the host owns the `~Copyable`
  /// value.
  var messagesInRange: (@MainActor (Range<Int>) -> [ScribeMessage])?
  /// Apply an `EditOp` (`.fork` or `.forkSplice`) to the host-owned
  /// document. The host updates transcript / banner / exit-hint state
  /// inline; the picker only needs to know the call succeeded.
  var applyEdit: (@MainActor (EditOp) async throws -> Void)?
  var configuration: ScribeConfig = ScribeConfig(
    agentModel: "", contextWindow: 0, contextWindowThreshold: 0,
    serverURL: "", apiKey: nil, workingDirectory: ".", reasoningEnabled: false)
  var logger: Logger = Logger(label: "scribe.picker.unset")
  var theme: CLITheme = .default
  var markdownRenderer: MarkdownRenderer = SwiftMarkdownRenderer()


  /// Set the model-busy flag on the host.
  var setModelBusy: ((Bool) -> Void)?

  /// Request a render frame.
  var requestRender: (() -> Void)?

  /// Whether the host is still active (not winding down).
  var isHostActive: (() -> Bool)?

  /// The current parent session id (for fork/tldr logging).
  var currentSessionId: (() -> UUID)?

  /// Enqueue a host event (for error reporting after failed picker action).
  var enqueueHostEvent: ((HostEvent) -> Void)?

  /// Restore host transcript/viewport/flattenCache from the controller's backup.
  /// Called from the error path of confirm (inside a Task, where inout params
  /// cannot be captured).
  var restoreHostFromBackup: (() -> Void)?


  /// Returns `true` when the picker consumed the action; the host should skip
  /// normal input processing for that action.
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


  /// Open the boundary picker.  Returns `true` when the picker is now active.
  ///
  /// The caller passes a borrow of the host-owned document. Without the
  /// doc the picker can't run; with `modelBusy == true` the content would
  /// be stale (mid-turn) so we refuse to open.
  func open(
    kind: PickerSnapshot.Kind,
    document: borrowing SessionDocument,
    modelBusy: Bool,
    transcriptState: inout TranscriptState,
    viewport: inout TranscriptViewport,
    flattenCache: inout TranscriptLayout.FlattenCache
  ) -> Bool {
    // Document lags the live coordinator while a turn is streaming.
    if modelBusy {
      logger.notice(
        "chat.picker.open.skip",
        metadata: ["kind": "\(kind)", "reason": "model-busy"])
      return false
    }
    let boundaries = document.safeForkBoundaries()
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
      kind: kind, document: document, boundaries: boundaries)
    let snap = PickerSnapshot(
      kind: kind,
      boundaries: boundaries,
      startCursor: startC,
      endCursor: endC,
      activeIsEnd: false,
      messageCount: document.count,
      previewText: Self.pickerPreview(document: document, at: boundaries[startC]))

    // Render disk-persisted history once so cursor moves only restyle.
    let rendered = renderDocumentToTranscriptWithStarts(
      document, theme: theme, renderer: markdownRenderer)
    var cachedMessages: [ScribeMessage] = []
    cachedMessages.reserveCapacity(document.count)
    for i in 0..<document.count {
      cachedMessages.append(document[i])
    }
    self.pickerMessages = cachedMessages
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
    requestRender?()
  }

  /// Cancel any running picker action task (called on host teardown).
  func cancelTask() {
    pickerActionTask?.cancel()
    pickerActionTask = nil
  }

  /// Clear all picker state without restoring from backup.
  /// Used during hot-swap when the transcript is about to be replaced entirely.
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

  /// Tab handler for `.tldr`: swap which cursor the arrow keys address.
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
    let parentSessionId = currentSessionId?() ?? UUID()
    let enqueue = enqueueHostEvent
    guard let applyEdit = self.applyEdit, let messagesInRange = self.messagesInRange else {
      logger.warning("chat.picker.confirm.skip", metadata: ["reason": "no-document-callbacks"])
      setModelBusy?(false)
      requestRender?()
      return
    }

    logger.notice(
      "chat.picker.confirm",
      metadata: [
        "kind": "\(kind)",
        "start_cut": "\(startCut)",
        "end_cut": kind == .tldr ? "\(endCut)" : "n/a",
      ])

    setModelBusy?(true)
    requestRender?()

    pickerActionTask?.cancel()
    pickerActionTask = Task { [weak self, applyEdit, messagesInRange] in
      guard let self else { return }
      do {
        guard await MainActor.run(body: { self.isHostActive?() ?? false }) else { return }

        let newId = UUID()
        switch kind {
        case .fork:
          try await applyEdit(.fork(cutAt: startCut, newSessionId: newId))
          logger.notice(
            "chat.fork.create",
            metadata: [
              "parent": "\(parentSessionId.uuidString)",
              "child": "\(newId.uuidString)",
              "cut_at": "\(startCut)",
            ])
        case .tldr:
          let slice = await MainActor.run {
            messagesInRange(startCut..<endCut)
          }
          let summary = try await SessionSummarizer.summarize(
            slice: slice, configuration: configuration, logger: logger)
          let replacement = [ScribeMessage(role: .assistant, content: summary)]
          try await applyEdit(
            .forkSplice(
              startCut: startCut,
              endCut: endCut,
              replacement: replacement,
              newSessionId: newId))
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
        // `applyEdit` inside the host already updates transcript / banner /
        // exit hint inline. The picker only needs to release model-busy here.
        await MainActor.run { [weak self] in
          guard let self, self.isHostActive?() ?? false else { return }
          self.setModelBusy?(false)
          self.requestRender?()
        }
      } catch {
        if Task.isCancelled { return }
        let se = (error as? ScribeError) ?? .generic(String(describing: error))
        logger.error(
          "chat.picker.action.fail",
          metadata: ["err": "\(se.errorDescription ?? String(describing: se))"])
        enqueue?(.transcript(.lifecycle(.error(se))))
        await MainActor.run { [weak self] in
          guard let self, self.isHostActive?() ?? false else { return }
          self.restoreHostFromBackup?()
          self.picker = nil
          self.pickerBackup = nil
          self.pickerMessages = []
          self.pickerBaseLines = []
          self.pickerBaseStarts = []
          self.scrollDirty = false
          self.setModelBusy?(false)
          self.requestRender?()
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
    requestRender?()
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


  /// Build the picker-styled transcript lines and divider index.
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

  /// One-line preview of the message at `index`.
  static func pickerPreview(document: borrowing SessionDocument, at index: Int) -> String {
    if index >= document.count { return "<end of session>" }
    return previewText(for: document[index])
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

  /// Compute the picker's default cursor positions.
  static func defaultCursor(
    kind: PickerSnapshot.Kind, document: borrowing SessionDocument, boundaries: [Int]
  ) -> (start: Int, end: Int?) {
    guard !boundaries.isEmpty else { return (0, nil) }
    switch kind {
    case .fork:
      return (boundaries.count - 1, nil)
    case .tldr:
      let endIdx = boundaries.count - 1
      let startIdx: Int = {
        var lastUser: Int?
        for i in 0..<document.count where document[i].role == .user {
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
