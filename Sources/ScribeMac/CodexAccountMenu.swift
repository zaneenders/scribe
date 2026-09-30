import Chroma
import Foundation
import ScribeCodexAuth

struct CodexAccountMenu: Block {
  let store: ScribeMacStore
  let theme: MacTheme

  @MainActor var body: some Block {
    ZStack {
      Interactive(action: { store.showCodexMenu = false }) { _ in
        Spacer().sizing(x: .grow, y: .grow)
      }
      VStack(spacing: 0) {
        HStack(spacing: 0) {
          Spacer()
          VStack(spacing: 12) {
            HStack(spacing: 8) {
              Text("CODEX").fontScale(theme.smallScale).foregroundColor(theme.accent)
              Spacer()
              Button("Close", fontScale: theme.smallScale) { store.showCodexMenu = false }
            }
            if store.isSignedInToCodex {
              if let window = store.codexUsage?.rateLimit?.primaryWindow {
                usageWindow(window, fallbackTitle: "Short-term")
              }
              if let window = store.codexUsage?.rateLimit?.secondaryWindow {
                usageWindow(window, fallbackTitle: "Weekly")
              }
              if store.isLoadingCodexUsage {
                Text("Loading usage...").fontScale(theme.smallScale).foregroundColor(theme.textSecondary)
              } else if let status = store.codexUsageStatus {
                Text(status).fontScale(theme.smallScale).foregroundColor(theme.textSecondary)
              }
              Button("Refresh usage", fontScale: theme.smallScale) { store.refreshCodexUsage() }
            } else {
              if let status = store.codexSignInStatus {
                WrappedText(text: status, theme: theme, color: theme.textSecondary, scale: theme.smallScale)
              }
              Button(
                store.isSigningInToCodex ? "Cancel sign-in" : "Sign in to Codex",
                fontScale: theme.smallScale
              ) {
                if store.isSigningInToCodex { store.cancelCodexSignIn() } else { store.signInToCodex() }
              }
            }
          }
          .padding(16)
          .sizing(x: .fixed(320), y: .fit)
          .background(theme.panelBackground)
          .border(theme.border)
        }
        Spacer()
      }
      .padding(EdgeInsets(top: theme.headerHeight, leading: 0, bottom: 0, trailing: theme.margin))
      .sizing(x: .grow, y: .grow)
    }
  }

  @MainActor private func usageWindow(_ window: CodexUsage.Window, fallbackTitle: String) -> some Block {
    let title =
      window.limitWindowSeconds == 18_000 ? "5-hour" : window.limitWindowSeconds == 604_800 ? "Weekly" : fallbackTitle
    let remaining = window.remainingPercent
    return VStack(spacing: 6) {
      HStack(spacing: 8) {
        Text(title).fontScale(theme.smallScale).foregroundColor(theme.textPrimary)
        Spacer()
        Text("\(Int(remaining))% left").fontScale(theme.smallScale).foregroundColor(theme.textSecondary)
      }
      HStack(spacing: 0) {
        Spacer().sizing(x: .fixed(Float(remaining / 100) * 288), y: .fixed(6))
          .background(remaining <= 10 ? theme.red : theme.accent)
        Spacer()
      }
      .sizing(x: .fixed(288), y: .fixed(6))
      .background(theme.buttonIdle)
      Text(
        "Resets \(Date(timeIntervalSince1970: Double(window.resetAt)).formatted(date: .abbreviated, time: .shortened))"
      )
      .fontScale(theme.smallScale).foregroundColor(theme.textSecondary)
    }
  }
}
