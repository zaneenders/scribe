import Chroma
import Foundation

/// The bottom-most bar: run state, working directory, session id, and usage.
struct StatusBar: Block {
  let store: ScribeMacStore
  let session: SessionController
  let theme: MacTheme

  @MainActor var body: some Block {
    HStack(spacing: 10) {
      Text(session.isRunning ? "WORKING" : "READY")
        .fontScale(theme.smallScale)
        .foregroundColor(session.isRunning ? theme.yellow : theme.green)
      Interactive(
        id: WidgetID("cwd-toggle"),
        action: { store.toggleDirectoryPicker() }
      ) { phase in
        HStack(spacing: 4) {
          Text("cwd")
            .fontScale(theme.smallScale)
            .foregroundColor(theme.textSecondary)
          Text(sanitizeASCII(session.workingDirectory))
            .fontScale(theme.smallScale)
            .foregroundColor(phase == .hovered ? theme.accent : theme.textPrimary)
        }
        .padding(EdgeInsets(top: 2, leading: 6, bottom: 2, trailing: 6))
        .background(phase == .hovered ? theme.buttonHover : theme.buttonIdle)
      }
      Text("Session: \(session.sessionIdText)")
        .fontScale(theme.smallScale).foregroundColor(theme.textSecondary)
        .selectable(WidgetID("session-id"))
      Spacer()
      if !session.usageText.isEmpty {
        Text(session.usageText).fontScale(theme.smallScale).foregroundColor(theme.textSecondary)
      }
    }
    .padding(EdgeInsets(top: 6, leading: theme.margin, bottom: 6, trailing: theme.margin))
    .sizing(y: .fixed(theme.statusHeight))
    .sizing(x: .grow)
    .background(theme.statusBackground)
  }
}
