import Chroma

struct StatusBar: Block {
  let store: ScribeMacStore
  let session: SessionController
  let theme: MacTheme

  @MainActor var body: some Block {
    HStack(spacing: 10) {
      if session.isRunning {
        HStack(spacing: 5) {
          ActivitySpinner(color: theme.purple)
          Text("WORKING").fontScale(theme.smallScale).foregroundColor(theme.purple)
        }
      } else {
        HStack(spacing: 5) {
          Text("●").fontScale(theme.smallScale).foregroundColor(theme.green)
          Text("READY").fontScale(theme.smallScale).foregroundColor(theme.green)
        }
      }
      Interactive(
        action: { store.toggleDirectoryPicker() }
      ) { phase in
        HStack(spacing: 4) {
          Text("⌂")
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
        .selectable()
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
