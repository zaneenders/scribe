import Chroma
import Foundation

struct ScribeMacRoot: Block {
  let store: ScribeMacStore
  let theme = MacTheme()

  @MainActor var body: some Block {
    RenderContextBridge(content: VStack(spacing: 0) {
      header
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
          if store.isSessionSidebarVisible {
            SessionSidebar(store: store, theme: theme)
          }
          if store.requiresDirectoryBeforeStart && store.showDirectoryPicker {
            DirectoryPalette(store: store, theme: theme, required: true)
          } else if let active = store.active {
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
      context.setCopyTextProvider {
        SelectionManager.shared.selectedText()
      }
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
    VStack(spacing: 0) {
      Spacer()
      HStack(spacing: 0) {
        Spacer()
        VStack(spacing: 14) {
          HStack(spacing: 8) {
            Text("◆").fontScale(theme.smallScale).foregroundColor(theme.accent)
            Text("START A WORKSPACE")
              .fontScale(theme.smallScale)
              .foregroundColor(theme.accent)
            Spacer()
          }
          HStack(spacing: 0) {
            Text("No session open")
              .fontScale(theme.textScale)
              .foregroundColor(theme.textPrimary)
            Spacer()
          }
          WrappedText(
            text: "Choose a project folder to start a new session, or continue your most recent conversation.",
            theme: theme, color: theme.textSecondary, scale: theme.smallScale)
          HStack(spacing: 8) {
            Button(
              "Choose project", id: WidgetID("empty-new"), fontScale: theme.textScale,
              style: theme.buttonStyle(pressedColor: theme.accent),
              padding: EdgeInsets(top: 8, leading: 14, bottom: 8, trailing: 14)
            ) { store.newSession() }
            Button(
              "Resume latest", id: WidgetID("empty-resume"), fontScale: theme.textScale,
              padding: EdgeInsets(top: 8, leading: 14, bottom: 8, trailing: 14)
            ) { store.resumeLatest() }
            Spacer()
          }
          WrappedText(
            text: "Tip: select any saved session in the sidebar to open it directly.",
            theme: theme, color: theme.textSecondary, scale: theme.smallScale)
        }
        .padding(EdgeInsets(top: 22, leading: 24, bottom: 22, trailing: 24))
        .sizing(x: .fixed(560))
        .background(theme.panelBackground)
        .border(theme.border)
        Spacer()
      }
      Spacer()
    }
    .sizing(x: .grow, y: .grow)
    .background(theme.background)
  }

  @MainActor private var header: some Block {
    HStack(spacing: 8) {
      Text("SCRIBE")
        .fontScale(theme.titleScale)
        .fontFace(.display)
        .foregroundColor(theme.accent)
      Button(
        store.isSessionSidebarVisible ? "Sessions ◀" : "Sessions ▶",
        id: WidgetID("sidebar-toggle"), fontScale: theme.smallScale,
        padding: EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8)
      ) { store.toggleSessionSidebar() }
      if let session = store.active {
        Text("│")
          .fontScale(theme.smallScale)
          .foregroundColor(theme.border)
          .padding(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4))
        HStack(spacing: 0) {
          headerTabButton(.chat, session: session)
          headerTabButton(.terminal, session: session)
        }
      }
      Spacer()
    }
    .padding(EdgeInsets(top: 2, leading: theme.margin, bottom: 2, trailing: theme.margin))
    .sizing(y: .fixed(theme.headerHeight))
    .sizing(x: .grow)
    .background(theme.headerBackground)
    .border(theme.border)
  }

  @MainActor private func headerTabButton(
    _ tab: SessionController.ContentTab, session: SessionController
  ) -> some Block {
    let active = session.selectedTab == tab
    return Interactive(
      id: WidgetID("session-tab-\(tab.rawValue).\(session.sessionId.uuidString)"),
      action: { session.selectTab(tab) }
    ) { phase in
      Text(tab == .chat ? "Chat" : "Terminal")
        .fontScale(theme.smallScale)
        .foregroundColor(
          active ? theme.accent : phase == .hovered ? theme.textPrimary : theme.textSecondary
        )
        .padding(EdgeInsets(top: 4, leading: 10, bottom: 4, trailing: 10))
        .background(
          active ? theme.panelBackground : phase == .hovered ? theme.sidebarHover : .clear
        )
        .border(active ? theme.accent : .clear, width: active ? 1 : 0)
    }
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

}
