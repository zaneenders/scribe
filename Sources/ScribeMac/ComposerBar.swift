import Chroma
import Foundation

/// Everything below the transcript: the queued-message tray (when non-empty),
/// the composer, and the status bar.
struct BottomChrome: Block {
  let store: ScribeMacStore
  let session: SessionController
  let theme: MacTheme

  @MainActor var body: some Block {
    VStack(spacing: 0, alignment: .leading) {
      if !session.queuedTexts.isEmpty {
        QueuedTray(session: session, theme: theme)
      }
      ComposerBar(session: session, theme: theme)
      StatusBar(store: store, session: session, theme: theme)
    }
    .frame(maxWidth: .infinity, alignment: .topLeading)
  }
}

struct ComposerBar: Block {
  let session: SessionController
  let theme: MacTheme

  @MainActor var body: some Block {
    HStack(spacing: 8, alignment: .bottom) {
      GrowingTextField(
        session.isRunning ? "Queue a message..." : "Message Scribe",
        id: ScribeMacStore.composerID,
        fontScale: theme.textScale,
        text: { session.draft },
        onChange: { session.updateDraft($0) },
        onNewline: { session.insertComposerNewline() }
      )
      VStack(spacing: 4, alignment: .trailing) {
        if session.isRunning {
          HStack(spacing: 6) {
            Button(
              "Queue", id: WidgetID("queue"), fontScale: theme.textScale,
              pressedColor: theme.accent
            ) { session.submit() }
            Button(
              "Stop", id: WidgetID("stop"), fontScale: theme.textScale,
              pressedColor: theme.red
            ) { session.stop() }
          }
        } else {
          Button(
            "Send", id: WidgetID("send"), fontScale: theme.textScale,
            pressedColor: theme.accent
          ) { session.submit() }
        }
        Text(session.isRunning ? "Cmd+Return queue | Esc stop" : "Cmd+Return send")
          .fontScale(theme.smallScale)
          .foregroundColor(theme.textSecondary)
      }
    }
    .padding(theme.margin)
    .frame(maxWidth: .infinity, alignment: .topLeading)
    .background(theme.composerBackground)
    .border(theme.border)
  }
}

struct QueuedTray: Block {
  let session: SessionController
  let theme: MacTheme

  @MainActor var body: some Block {
    let queued = session.queuedTexts
    return VStack(spacing: 4, alignment: .leading) {
      HStack(spacing: 8) {
        Text("QUEUED (\(queued.count)) · sent in order after each turn")
          .fontScale(theme.smallScale)
          .foregroundColor(theme.yellow)
        Spacer()
        Button(
          "Send next", id: WidgetID("force-send-queue"), fontScale: theme.smallScale,
          pressedColor: theme.accent,
          padding: EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8)
        ) { session.forceSendNext() }
        Button(
          "Clear", id: WidgetID("clear-queue"), fontScale: theme.smallScale,
          padding: EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8)
        ) { session.clearQueue() }
      }
      for (index, text) in queued.enumerated() {
        Text("[\(index + 1)/\(queued.count)] \(queuePreview(text))")
          .fontScale(theme.smallScale)
          .foregroundColor(index == 0 ? theme.textPrimary : theme.textSecondary)
      }
    }
    .padding(EdgeInsets(top: 6, leading: theme.margin, bottom: 6, trailing: theme.margin))
    .frame(maxWidth: .infinity, alignment: .topLeading)
    .background(theme.statusBackground)
    .border(theme.border)
  }

  private func queuePreview(_ text: String, limit: Int = 100) -> String {
    let flat = sanitizeASCII(text.replacingOccurrences(of: "\n", with: " "))
    guard flat.count > limit else { return flat }
    return String(flat.prefix(limit - 3)) + "..."
  }
}
