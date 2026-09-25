import Chroma
import Foundation

struct ScribeMacRoot: Block {
  let store: ScribeMacStore
  let theme: MacTheme

  @MainActor var body: some Block {
    RenderContextBridge(
      content: ZStack {
        VStack(spacing: 0) {
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
                Button("New session", fontScale: theme.textScale) {
                  store.newSession()
                }
                Button("Resume latest", fontScale: theme.textScale) {
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
              } else if theme.appearance == .compact {
                compactEmptyState
              } else {
                emptyState
              }
            }
            .sizing(x: .grow, y: .grow)
          }
        }
        .background(theme.background)
        if let sessionID = store.renamingSessionID {
          RenameSessionDialog(store: store, sessionID: sessionID, theme: theme)
        }
      },
      prepare: { context in
        context.setCopyTextProvider {
          let text = SelectionManager.shared.copyText(
            isTranscriptVisible: store.active != nil)
          if ProcessInfo.processInfo.environment["SCRIBE_DEBUG_CLIPBOARD"] == "1" {
            let message =
              "[scribe.clipboard] transcriptVisible=\(store.active != nil) selectedCharacters=\(text?.count ?? 0)\n"
            try? FileHandle.standardError.write(contentsOf: Data(message.utf8))
          }
          return text
        }
        context.setSelectAllHandler {
          SelectionManager.shared.selectAll(
            isTranscriptVisible: store.active != nil)
        }
        if context.input.pointerPressed {
          SelectionManager.shared.clear()
        }
        SelectionManager.shared.updateFromDrag(context: context)
        MarkdownLayoutRegistry.clear()
        store.applyPendingFocus()
        if store.showDirectoryPicker, store.renamingSessionID == nil {
          if context.input.commands.contains(ScribeCommandPickerCommand.toggle) {
            store.tabCompleteDirectory()
          }
        }
        for command in context.input.commands {
          if !store.showDirectoryPicker, store.renamingSessionID == nil,
            store.active?.commandPicker == nil,
            ScribeComposerCommand.shouldSubmit(command, composerFocus: ScribeMacStore.composerFocus)
          {
            store.active?.submit()
          }
        }
      },
      finish: { context in
        store.finishDirectoryPaletteInput(context)
      })
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

  @MainActor private var compactEmptyState: some Block {
    VStack(spacing: 0) {
      VStack(spacing: 6) {
        HStack(spacing: 6) {
          Text("◆").fontScale(theme.smallScale).foregroundColor(theme.green)
          Text("NEW SESSION").fontScale(theme.smallScale).foregroundColor(theme.green)
          Spacer()
        }
        WrappedText(
          text: "Choose a project folder to start a session, or pick one from the sidebar to continue.",
          theme: theme, color: theme.textSecondary, scale: theme.textScale)
        HStack(spacing: 8) {
          Button("Choose project", fontScale: theme.smallScale,
            style: theme.buttonStyle(tint: theme.peach)) { store.newSession() }
          Button("Resume latest", fontScale: theme.smallScale,
            style: theme.buttonStyle(tint: theme.blue)) { store.resumeLatest() }
          Spacer()
        }
      }
      .padding(theme.panelPadding)
      .sizing(x: .grow)
      .roundedBackground(theme.panelBackground, radius: 7)
      .roundedBorder(theme.border, radius: 7)
      .padding(EdgeInsets(top: 4, leading: theme.margin, bottom: 4, trailing: theme.margin))
      Spacer()
    }
    .sizing(x: .grow, y: .grow)
    .background(theme.background)
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
              "Choose project", fontScale: theme.textScale,
              style: theme.buttonStyle(pressedColor: theme.accent),
              padding: EdgeInsets(top: 8, leading: 14, bottom: 8, trailing: 14)
            ) { store.newSession() }
            Button(
              "Resume latest", fontScale: theme.textScale,
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
      Text(theme.appearance == .compact ? "Scribe" : "SCRIBE")
        .fontScale(theme.titleScale)
        .foregroundColor(theme.appearance == .compact ? theme.textPrimary : theme.accent)
      Button(
        store.isSessionSidebarVisible ? "Sessions ◀" : "Sessions ▶", fontScale: theme.smallScale,
        style: theme.appearance == .compact ? theme.buttonStyle(tint: theme.red) : nil,
        padding: EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8)
      ) { store.toggleSessionSidebar() }
      Spacer()
      if ScribeSceneCapture.shared.isEnabled {
        Button(
          ScribeSceneCapture.shared.status,
          fontScale: theme.smallScale,
          padding: EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8)
        ) { ScribeSceneCapture.shared.request() }
      }
    }
    .padding(EdgeInsets(top: 2, leading: theme.margin, bottom: 2, trailing: theme.margin))
    .sizing(y: .fixed(theme.headerHeight))
    .sizing(x: .grow)
    .background(theme.headerBackground)
    .border(theme.appearance == .compact ? .clear : theme.border)
  }

  @MainActor private func errorBanner(_ message: String) -> some Block {
    HStack(spacing: 8) {
      Text(sanitizeASCII(message))
        .fontScale(theme.smallScale)
        .foregroundColor(theme.errorText)
      Spacer()
      Button(
        "Dismiss", fontScale: theme.smallScale,
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
