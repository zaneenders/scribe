import Chroma
import Foundation

/// The main content area of a ready session: scrolling transcript above the
/// composer and status chrome.
struct ReadyLayout: Block {
  let store: ScribeMacStore
  let session: SessionController
  let theme: MacTheme

  @MainActor var body: some Block {
    VStack(spacing: 0) {
      SessionTabStrip(session: session, theme: theme)
      switch session.selectedTab {
      case .chat:
        TranscriptView(session: session, theme: theme)
        BottomChrome(store: store, session: session, theme: theme)
      case .terminal:
        if let terminal = session.terminal {
          TerminalTabContent(terminal: terminal, theme: theme)
            .sizing(x: .grow, y: .grow)
            .background(theme.panelBackground)
        }
        StatusBar(store: store, session: session, theme: theme)
      }
    }
    .sizing(x: .grow, y: .grow)
  }
}

struct TranscriptView: Block {
  let session: SessionController
  let theme: MacTheme

  @MainActor var body: some Block {
    let rows: [LazyVStack.Row]
    if session.transcript.isEmpty {
      rows = [
        LazyVStack.Row(
          id: WidgetID("transcript-empty"),
          content: VStack(spacing: 8) {
            Text(session.isLoadingTranscript ? "Loading transcript..." : "Ready")
              .fontScale(theme.textScale).foregroundColor(theme.accent)
            WrappedText(
              text: session.isLoadingTranscript
                ? "The session is ready; conversation history is still being prepared."
                : "Ask Scribe to inspect, explain, or change the current project.",
              theme: theme, color: theme.textSecondary)
          }
          .padding(theme.panelPadding)
          .sizing(x: .grow)
        )
      ]
    } else {
      rows = transcriptRows()
    }
    // The scroll identity is per session, so each session keeps its own
    // scroll position while switching.
    return CommandRevealTranscript(
      id: WidgetID("transcript:\(session.sessionId.uuidString)"),
      session: session, controller: session.scroll, rows: rows,
      revealRow: activeBoundaryRow(in: rows)
    )
    .sizing(x: .grow, y: .grow)
    .background(theme.panelBackground)
  }

  @MainActor private func activeBoundaryRow(in rows: [LazyVStack.Row]) -> Int? {
    guard let picker = session.commandPicker else { return nil }
    let isStart = picker.command == .fork || !picker.activeIsEnd
    let id = WidgetID(
      "command-boundary:\(picker.command.rawValue):\(picker.activeBoundary):\(isStart)")
    return rows.firstIndex { $0.id == id }
  }

  @MainActor private func transcriptRows() -> [LazyVStack.Row] {
    guard let picker = session.commandPicker else {
      return session.transcript.map { transcriptRow($0, selection: .none) }
    }

    var rows: [LazyVStack.Row] = []
    var insertedBoundaries: Set<Int> = []
    for item in session.transcript {
      if let index = item.sourceMessageIndex {
        if index == picker.startBoundary, insertedBoundaries.insert(index).inserted {
          rows.append(boundaryRow(at: index, isStart: true, picker: picker))
        }
        if picker.command == .tldr, index == picker.endBoundary,
          insertedBoundaries.insert(index).inserted
        {
          rows.append(boundaryRow(at: index, isStart: false, picker: picker))
        }
      }
      rows.append(transcriptRow(item, selection: selection(for: item, picker: picker)))
    }
    if picker.startBoundary == picker.messageCount,
      insertedBoundaries.insert(picker.startBoundary).inserted
    {
      rows.append(boundaryRow(at: picker.startBoundary, isStart: true, picker: picker))
    }
    if picker.command == .tldr, picker.endBoundary == picker.messageCount,
      insertedBoundaries.insert(picker.endBoundary).inserted
    {
      rows.append(boundaryRow(at: picker.endBoundary, isStart: false, picker: picker))
    }
    return rows
  }

  @MainActor private func transcriptRow(
    _ item: SessionController.TranscriptItem, selection: TranscriptSelection
  ) -> LazyVStack.Row {
    LazyVStack.Row(
      id: item.layoutID,
      content: TranscriptItemBlock(item: item, theme: theme, selection: selection)
        .padding(
          EdgeInsets(
            top: theme.spacing / 2, leading: theme.margin,
            bottom: theme.spacing / 2, trailing: theme.margin)
        )
        .sizing(x: .grow)
    )
  }

  private func selection(
    for item: SessionController.TranscriptItem,
    picker: SessionController.CommandPickerState
  ) -> TranscriptSelection {
    guard let index = item.sourceMessageIndex else { return .none }
    switch picker.command {
    case .fork:
      return index >= picker.startBoundary ? .discarded : .none
    case .tldr:
      return index >= picker.startBoundary && index < picker.endBoundary ? .collapsed : .none
    }
  }

  @MainActor private func boundaryRow(
    at boundary: Int, isStart: Bool, picker: SessionController.CommandPickerState
  ) -> LazyVStack.Row {
    let active = picker.command == .fork || (isStart != picker.activeIsEnd)
    let label: String
    switch picker.command {
    case .fork:
      label = "FORK CUT · EVERYTHING BELOW WILL BE DISCARDED"
    case .tldr:
      label =
        isStart
        ? "TLDR START · SUMMARY BEGINS HERE"
        : "TLDR END · CONVERSATION BELOW IS PRESERVED"
    }
    return LazyVStack.Row(
      id: WidgetID("command-boundary:\(picker.command.rawValue):\(boundary):\(isStart)"),
      content: CommandBoundaryMarker(
        label: label, active: active,
        color: picker.command == .fork ? theme.red : theme.yellow,
        theme: theme
      )
      .padding(EdgeInsets(top: 5, leading: theme.margin, bottom: 5, trailing: theme.margin))
      .sizing(x: .grow)
    )
  }
}

enum TranscriptSelection {
  case none
  case collapsed
  case discarded
}

private struct CommandBoundaryMarker: PrimitiveBlock {
  let label: String
  let active: Bool
  let color: Color
  let theme: MacTheme

  @MainActor var expandsHorizontally: Bool { true }

  @MainActor func sizeThatFits(_ proposal: Size, context: RenderContext) -> Size {
    Size(width: proposal.width, height: 30)
  }

  @MainActor func draw(into drawList: inout DrawList, in rect: Rect, context: RenderContext) {
    let content = HStack(spacing: 8) {
      Text("────").fontScale(theme.smallScale).foregroundColor(active ? color : theme.textSecondary)
      Text(label)
        .fontScale(theme.smallScale)
        .foregroundColor(active ? color : theme.textSecondary)
      Spacer()
      Text("────").fontScale(theme.smallScale).foregroundColor(active ? color : theme.textSecondary)
    }
    .padding(EdgeInsets(top: 5, leading: 8, bottom: 5, trailing: 8))
    .sizing(x: .grow)
    .background(active ? theme.statusBackground : theme.panelBackground)
    BlockEngine.draw(content, into: &drawList, in: rect, context: context)
  }
}

/// Pins the active command boundary to the top of the transcript viewport.
/// LazyVStack only draws visible rows, so a marker cannot request its own reveal
/// after it moves off-screen. This wrapper measures the rows before the marker
/// and queues the exact content offset before LazyVStack handles the frame.
private struct CommandRevealTranscript: PrimitiveBlock {
  let id: WidgetID
  let session: SessionController
  let controller: ScrollViewController
  let rows: [LazyVStack.Row]
  let revealRow: Int?

  @MainActor var expandsHorizontally: Bool { true }
  @MainActor var expandsVertically: Bool { true }

  @MainActor func sizeThatFits(_ proposal: Size, context: RenderContext) -> Size { proposal }

  @MainActor func draw(into drawList: inout DrawList, in rect: Rect, context: RenderContext) {
    if let revealRow, session.consumeCommandReveal() {
      var offset: Float = 0
      for index in 0..<revealRow {
        offset +=
          BlockEngine.measure(
            rows[index].content,
            proposal: Size(width: rect.size.width, height: Float.greatestFiniteMagnitude),
            context: context
          ).height
      }
      controller.scroll(to: offset)
    }
    let stack = LazyVStack(
      id: id, sticksToBottom: true, controller: controller, rows: rows)
    TranscriptViewportRegistry.current = rect
    defer { TranscriptViewportRegistry.current = nil }
    BlockEngine.draw(stack, into: &drawList, in: rect, context: context)
  }
}

struct TranscriptItemBlock: Block {
  let item: SessionController.TranscriptItem
  let theme: MacTheme
  var selection: TranscriptSelection = .none

  @MainActor var body: some Block {
    VStack(spacing: 7) {
      HStack(spacing: 6) {
        Text(labelMarker).fontScale(theme.smallScale).foregroundColor(labelColor)
        Text(label).fontScale(theme.smallScale).foregroundColor(labelColor)
        Spacer()
      }
      if item.text.isEmpty {
        Text(item.running ? "running..." : "(empty)")
          .fontScale(theme.smallScale).foregroundColor(theme.textSecondary)
      } else if item.kind == .answer || item.kind == .reasoning {
        MarkdownText(
          markdown: item.text, theme: theme, baseColor: bodyColor,
          scale: theme.textScale, itemID: item.layoutID)
      } else {
        WrappedText(
          text: item.text, theme: theme, color: bodyColor,
          scale: theme.textScale, itemID: item.layoutID)
      }
    }
    .padding(theme.panelPadding)
    .sizing(x: .grow)
    .background(backgroundColor)
    .border(selection == .none ? theme.border : selectionColor)
  }

  private var label: String {
    item.running ? "\(sanitizeASCII(item.title)) · running" : sanitizeASCII(item.title)
  }

  private var labelMarker: String {
    switch item.kind {
    case .user: ">"
    case .answer: "◆"
    case .reasoning: "◇"
    case .tool: "⌘"
    case .notice: "·"
    case .warning: "!"
    case .error: "×"
    }
  }

  private var labelColor: Color {
    switch item.kind {
    case .user: theme.accent
    case .answer: theme.green
    case .reasoning: theme.purple
    case .tool: theme.toolHeaderText
    case .notice: theme.textSecondary
    case .warning: theme.warningText
    case .error: theme.errorText
    }
  }

  private var bodyColor: Color {
    if selection != .none { return theme.textSecondary }
    return switch item.kind {
    case .reasoning: theme.reasoningText
    case .tool: theme.toolOutputText
    case .warning: theme.warningText
    case .error: theme.errorText
    default: theme.textPrimary
    }
  }

  private var selectionColor: Color {
    switch selection {
    case .none: theme.border
    case .collapsed: theme.yellow
    case .discarded: theme.red
    }
  }

  private var backgroundColor: Color {
    if selection != .none { return theme.statusBackground }
    return switch item.kind {
    case .user: theme.userBubbleBackground
    case .tool: theme.codeBackground
    default: theme.panelBackground
    }
  }
}
