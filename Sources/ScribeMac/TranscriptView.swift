import Chroma
import Foundation

/// The main content area of a ready session: scrolling transcript above the
/// composer and status chrome.
struct ReadyLayout: Block {
  let store: ScribeMacStore
  let session: SessionController
  let theme: MacTheme

  @MainActor var body: some Block {
    VStack(spacing: 0, alignment: .leading) {
      TranscriptView(session: session, theme: theme)
      BottomChrome(store: store, session: session, theme: theme)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
          content: VStack(spacing: 8, alignment: .leading) {
            Text("Ready").fontScale(theme.textScale).foregroundColor(theme.accent)
            WrappedText(
              text: "Ask Scribe to inspect, explain, or change the current project.",
              theme: theme, color: theme.textSecondary)
          }
          .padding(theme.panelPadding)
          .frame(maxWidth: .infinity, alignment: .topLeading)
        )
      ]
    } else {
      rows = session.transcript.map { item in
        LazyVStack.Row(
          id: item.layoutID,
          content: TranscriptItemBlock(item: item, theme: theme)
            .padding(
              EdgeInsets(
                top: theme.spacing / 2, leading: theme.margin,
                bottom: theme.spacing / 2, trailing: theme.margin)
            )
            .frame(maxWidth: .infinity, alignment: .topLeading)
        )
      }
    }
    // The scroll identity is per session, so each session keeps its own
    // scroll position while switching.
    return LazyVStack(
      id: WidgetID("transcript:\(session.sessionId.uuidString)"), sticksToBottom: true,
      controller: session.scroll, rows: rows
    )
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(theme.panelBackground)
  }
}

struct TranscriptItemBlock: Block {
  let item: SessionController.TranscriptItem
  let theme: MacTheme

  @MainActor var body: some Block {
    VStack(spacing: 6, alignment: .leading) {
      Text(label).fontScale(theme.smallScale).foregroundColor(labelColor)
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
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(backgroundColor)
    .border(theme.border)
  }

  private var label: String {
    item.running ? "\(sanitizeASCII(item.title)) (running)" : sanitizeASCII(item.title)
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
    switch item.kind {
    case .reasoning: theme.reasoningText
    case .tool: theme.toolOutputText
    case .warning: theme.warningText
    case .error: theme.errorText
    default: theme.textPrimary
    }
  }

  private var backgroundColor: Color {
    switch item.kind {
    case .user: theme.userBubbleBackground
    case .tool: theme.codeBackground
    default: theme.panelBackground
    }
  }
}
