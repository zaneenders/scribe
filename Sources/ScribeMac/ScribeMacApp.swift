import Chroma
import Foundation
import MetalBackend

@main
struct ScribeMacApp: MetalApp {
  var title: String { "Scribe" }
  var windowSize: Size { Size(width: 1100, height: 760) }
  var minimumRefreshRate: Double { 30 }

  var keyBindings: KeyBindings {
    KeyBindings {
      bind("c", modifiers: .command, to: .editing(.copy))
      bind("v", modifiers: .command, to: .editing(.paste))
      bind("a", modifiers: .command, to: .editing(.selectAll))
      bind(.backspace, to: .editing(.backspace))
      bind(.delete, to: .editing(.deleteForward))
      bind(.leftArrow, to: .editing(.moveCaretLeft))
      bind(.rightArrow, to: .editing(.moveCaretRight))
      bind(.home, to: .editing(.moveCaretToStart))
      bind(.end, to: .editing(.moveCaretToEnd))
      bind(.enter, to: .editing(.submit))
      bind(.escape, to: .editing(.endEditing))
      bind(.space, to: .action(.activate))
      bind(.pageUp, to: .navigation(.pageUp))
      bind(.pageDown, to: .navigation(.pageDown))
    }
  }

  @MainActor var body: some Block {
    let store = ScribeMacStore.shared
    store.start()
    return ScribeMacRoot(store: store)
  }
}

struct ScribeMacRoot: Block {
  let store: ScribeMacStore
  let theme = MacTheme()

  @MainActor var body: some Block {
    RenderContextBridge(content: VStack(spacing: 0) {
      header
      if store.showModelPicker {
        modelPicker
      }
      if store.showDirectoryPicker && !store.requiresDirectoryBeforeStart {
        directoryPicker
      }
      if let error = store.lastError {
        errorBanner(error)
      }
      switch store.phase {
      case .starting:
        if store.showDirectoryPicker {
          DirectoryPalette(store: store, theme: theme, required: store.requiresDirectoryBeforeStart)
        } else {
          VStack(spacing: 12) {
            Spacer()
            Text("Starting Scribe...").fontScale(theme.textScale).foregroundColor(theme.textSecondary)
            Spacer()
          }
          .sizing(x: .grow, y: .grow)
        }
      case .failed(let message):
        VStack(spacing: 14) {
          Text("Could not start Scribe").fontScale(theme.textScale).foregroundColor(theme.errorText)
          WrappedText(text: message, theme: theme, color: theme.textPrimary)
          HStack(spacing: 8) {
            Button("New session", id: WidgetID("retry-new"), fontScale: theme.textScale) {
              store.newSession()
            }
            Button("Resume latest", id: WidgetID("retry-resume"), fontScale: theme.textScale) {
              store.resumeLatest()
            }
          }
          Spacer()
        }
        .padding(theme.margin)
        .sizing(x: .grow, y: .grow)
      case .ready:
        HStack(spacing: 0) {
          SessionSidebar(store: store, theme: theme)
          if let active = store.active {
            ReadyLayout(store: store, session: active, theme: theme)
          } else if let selected = store.selectedSavedSession {
            sessionLoadingState(selected)
          } else {
            emptyState
          }
        }
        .sizing(x: .grow, y: .grow)
      }
    }
    .background(theme.background)) { context in
      // Hit testing uses layouts retained from the preceding frame.
      if context.input.pointerPressed {
        SelectionManager.shared.clear()
      }
      SelectionManager.shared.updateFromDrag(context: context)
      MarkdownLayoutRegistry.clear()
      store.applyPendingFocus()
    }
  }

  @MainActor private func sessionLoadingState(_ saved: ScribeMacStore.SavedSession) -> some Block {
    VStack(spacing: 10) {
      Spacer()
      Text("Opening session...").fontScale(theme.textScale).foregroundColor(theme.accent)
      Text(String(saved.id.uuidString.prefix(8)).uppercased())
        .fontScale(theme.smallScale)
        .foregroundColor(theme.textSecondary)
      Text("Loading transcript and preparing the agent")
        .fontScale(theme.smallScale)
        .foregroundColor(theme.textSecondary)
      Spacer()
    }
    .sizing(x: .grow, y: .grow)
  }

  @MainActor private var emptyState: some Block {
    VStack(spacing: 12) {
      Spacer()
      Text("No session open").fontScale(theme.textScale).foregroundColor(theme.textSecondary)
      HStack(spacing: 8) {
        Button("New session", id: WidgetID("empty-new"), fontScale: theme.textScale) {
          store.newSession()
        }
        Button("Resume latest", id: WidgetID("empty-resume"), fontScale: theme.textScale) {
          store.resumeLatest()
        }
      }
      Spacer()
    }
    .sizing(x: .grow, y: .grow)
  }

  @MainActor private var header: some Block {
    HStack(spacing: 10) {
      Text("SCRIBE").fontScale(theme.titleScale).foregroundColor(theme.accent)
      Interactive(id: WidgetID("model-picker-toggle"), action: { store.toggleModelPicker() }) { phase in
        HStack(spacing: 4) {
          Text(profileLabel)
            .fontScale(theme.smallScale)
            .foregroundColor(phase == .hovered ? theme.accent : theme.textSecondary)
          Text(store.showModelPicker ? "▲" : "▼")
            .fontScale(theme.smallScale)
            .foregroundColor(theme.textSecondary)
        }
        .padding(EdgeInsets(top: 4, leading: 6, bottom: 4, trailing: 6))
        .background(phase == .hovered ? theme.buttonHover : theme.headerBackground)
      }
      Spacer()
      Button(
        "Directory", id: WidgetID("directory-toggle"), fontScale: theme.smallScale,
        padding: EdgeInsets(top: 6, leading: 10, bottom: 6, trailing: 10)
      ) { store.toggleDirectoryPicker() }
      Button(
        "New", id: WidgetID("new-session"), fontScale: theme.smallScale,
        padding: EdgeInsets(top: 6, leading: 10, bottom: 6, trailing: 10)
      ) { store.newSession() }
      Button(
        "Resume latest", id: WidgetID("resume-latest"), fontScale: theme.smallScale,
        padding: EdgeInsets(top: 6, leading: 10, bottom: 6, trailing: 10)
      ) { store.resumeLatest() }
    }
    .padding(EdgeInsets(top: 8, leading: theme.margin, bottom: 8, trailing: theme.margin))
    .sizing(y: .fixed(theme.headerHeight))
    .sizing(x: .grow)
    .background(theme.headerBackground)
    .border(theme.border)
  }

  @MainActor private var profileLabel: String {
    guard let active = store.active else { return "no session" }
    return "\(sanitizeASCII(active.profileName)) / \(sanitizeASCII(active.modelName))"
  }

  @MainActor private func errorBanner(_ message: String) -> some Block {
    HStack(spacing: 8) {
      Text(sanitizeASCII(message))
        .fontScale(theme.smallScale)
        .foregroundColor(theme.errorText)
      Spacer()
      Button(
        "Dismiss", id: WidgetID("error-dismiss"), fontScale: theme.smallScale,
        padding: EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8)
      ) { store.dismissError() }
    }
    .padding(EdgeInsets(top: 6, leading: theme.margin, bottom: 6, trailing: theme.margin))
    .sizing(x: .grow)
    .background(theme.statusBackground)
    .border(theme.border)
  }

  @MainActor private var directoryPicker: some Block {
    DirectoryPalette(store: store, theme: theme, required: false)
  }

  @MainActor private var modelPicker: some Block {
    let itemHeight: Float = 34
    let profiles = store.profileCatalog
    return VStack(spacing: 0) {
      for (_, profile) in profiles.enumerated() {
        let isActive = profile.name == store.active?.profileName
        Interactive(
          id: WidgetID("model-picker-item-\(profile.name)"),
          action: { store.selectProfile(profile.name) }
        ) { phase in
          HStack(spacing: 6) {
            Text(isActive ? "●" : " ")
              .fontScale(theme.smallScale)
              .foregroundColor(isActive ? theme.accent : .clear)
            Text(sanitizeASCII(profile.name))
              .fontScale(theme.smallScale)
              .foregroundColor(
                isActive
                  ? theme.accent
                  : phase == .hovered ? theme.textPrimary : theme.textSecondary)
            Spacer()
            Text(sanitizeASCII(profile.model))
              .fontScale(theme.smallScale)
              .foregroundColor(theme.textSecondary)
          }
          .padding(EdgeInsets(top: 6, leading: theme.margin, bottom: 6, trailing: theme.margin))
          .sizing(y: .fixed(itemHeight))
          .sizing(x: .grow)
          .background(
            phase == .hovered
              ? theme.buttonHover
              : isActive ? theme.buttonIdle : theme.panelBackground)
        }
      }
    }
    .sizing(x: .fixed(300))
    .background(theme.headerBackground)
    .border(theme.border)
  }
}
