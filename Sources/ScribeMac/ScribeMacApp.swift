import Chroma
import Foundation
import Logging
import MetalBackend
import ProfileRecorderServer

@main
struct ScribeMacApp: MetalApp {
  var title: String { "Scribe" }
  var windowSize: Size { Size(width: 1100, height: 760) }

  @MainActor var body: some Block {
    let store = ScribeMacStore.shared
    store.start()
    return ScribeMacRoot(store: store)
  }

  @MainActor static func main() {
    let profileRecorderTask = Task.detached {
      let logger = Logger(label: "scribe.mac.profile-recorder")
      do {
        #if DEBUG
        let environment = ProcessInfo.processInfo.environment
        if environment["PROFILE_RECORDER_SERVER_URL"] == nil
          && environment["PROFILE_RECORDER_SERVER_URL_PATTERN"] == nil
        {
          setenv(
            "PROFILE_RECORDER_SERVER_URL_PATTERN",
            "unix:///tmp/scribe-mac-{PID}.sock",
            0
          )
        }
        #endif
        let configuration = try await ProfileRecorderServerConfiguration.parseFromEnvironment()
        await ProfileRecorderServer(configuration: configuration).runIgnoringFailures(logger: logger)
      } catch {
        logger.warning("profile-recorder.configuration.failed", metadata: ["error": "\(error)"])
      }
    }
    defer { profileRecorderTask.cancel() }

    let app = Self()
    guard let renderer = MetalRenderer(size: app.windowSize) else {
      fatalError("Metal requires Apple Silicon or supported GPU.")
    }
    renderer.content = app.body
    renderer.onClose = { ScribeMacStore.shared.close() }
    renderer.run(title: app.title)
  }
}

struct ScribeMacRoot: Block {
  let store: ScribeMacStore
  let theme = MacTheme()

  @MainActor var body: some Block {
    let interaction = Interaction.current
    // Hit testing uses the layouts retained from the preceding frame. Update
    // the selection before clearing the registry for this frame's draw pass.
    if interaction.input.pointerPressed {
      SelectionManager.shared.clear()
    }
    SelectionManager.shared.updateFromDrag()
    MarkdownLayoutRegistry.clear()

    // Handle Cmd+C copy — check both selection managers
    interaction.onCopy = {
      if let markdown = SelectionManager.shared.selectedText() { return markdown }
      return TextSelectionManager.shared.selectedText()
    }

    store.applyPendingFocus()
    return VStack(spacing: 0, alignment: .leading) {
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
          .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
      case .failed(let message):
        VStack(spacing: 14, alignment: .leading) {
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
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      case .ready:
        HStack(spacing: 0) {
          SessionSidebar(store: store, theme: theme)
          if let active = store.active {
            ReadyLayout(store: store, session: active, theme: theme)
          } else {
            emptyState
          }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      }
    }
    .background(theme.background)
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
    .frame(maxWidth: .infinity, maxHeight: .infinity)
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
    .frame(height: theme.headerHeight, alignment: .leading)
    .frame(maxWidth: .infinity, alignment: .leading)
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
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(theme.statusBackground)
    .border(theme.border)
  }

  @MainActor private var directoryPicker: some Block {
    DirectoryPalette(store: store, theme: theme, required: false)
  }

  @MainActor private var modelPicker: some Block {
    let itemHeight: Float = 34
    let profiles = store.profileCatalog
    return VStack(spacing: 0, alignment: .leading) {
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
                isActive ? theme.accent
                  : phase == .hovered ? theme.textPrimary : theme.textSecondary)
            Spacer()
            Text(sanitizeASCII(profile.model))
              .fontScale(theme.smallScale)
              .foregroundColor(theme.textSecondary)
          }
          .padding(EdgeInsets(top: 6, leading: theme.margin, bottom: 6, trailing: theme.margin))
          .frame(height: itemHeight, alignment: .leading)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(
            phase == .hovered ? theme.buttonHover
              : isActive ? theme.buttonIdle : theme.panelBackground)
        }
      }
    }
    .frame(maxWidth: 300, alignment: .leading)
    .background(theme.headerBackground)
    .border(theme.border)
  }
}

/// Lists every open session with live status, so a turn keeps visibly running
/// in the background while another session is on screen.
private struct SessionSidebar: Block {
  let store: ScribeMacStore
  let theme: MacTheme

  @MainActor var body: some Block {
    VStack(spacing: 0, alignment: .leading) {
      HStack(spacing: 6) {
        Text("SESSIONS")
          .fontScale(theme.smallScale)
          .foregroundColor(theme.textSecondary)
        Spacer()
        Button(
          "+ New", id: WidgetID("sidebar-new"), fontScale: theme.smallScale,
          padding: EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8)
        ) { store.newSession() }
      }
      .padding(EdgeInsets(top: 8, leading: theme.margin, bottom: 8, trailing: 8))

      for session in store.sessions {
        SessionRow(
          store: store,
          session: session,
          theme: theme,
          isActive: session.sessionId == store.activeSessionID)
      }

      if store.pendingSessionCount > 0 {
        Text("Starting session...")
          .fontScale(theme.smallScale)
          .foregroundColor(theme.yellow)
          .padding(EdgeInsets(top: 4, leading: theme.margin, bottom: 4, trailing: theme.margin))
      }

      if store.sessions.isEmpty && store.pendingSessionCount == 0 {
        Text("No sessions")
          .fontScale(theme.smallScale)
          .foregroundColor(theme.textSecondary)
          .padding(EdgeInsets(top: 4, leading: theme.margin, bottom: 4, trailing: theme.margin))
      }

      Spacer()
    }
    .frame(width: 220)
    .frame(maxHeight: .infinity, alignment: .topLeading)
    .background(theme.statusBackground)
    .border(theme.border)
  }
}

private struct SessionRow: Block {
  let store: ScribeMacStore
  let session: SessionController
  let theme: MacTheme
  let isActive: Bool

  @MainActor var body: some Block {
    HStack(spacing: 2) {
      Interactive(
        id: WidgetID("session-row:\(session.sessionId.uuidString)"),
        action: { store.switchTo(session.sessionId) }
      ) { phase in
        HStack(spacing: 6) {
          Text("●")
            .fontScale(theme.smallScale)
            .foregroundColor(session.isRunning ? theme.yellow : theme.green)
          VStack(spacing: 2, alignment: .leading) {
            Text(sanitizeASCII(session.directoryTitle))
              .fontScale(theme.smallScale)
              .foregroundColor(
                isActive || phase == .hovered ? theme.textPrimary : theme.textSecondary)
            Text(sanitizeASCII("\(session.sessionIdText) · \(session.modelName)"))
              .fontScale(theme.smallScale)
              .foregroundColor(theme.textSecondary)
          }
          Spacer()
          if session.hasUnreadActivity && !isActive {
            Text("●")
              .fontScale(theme.smallScale)
              .foregroundColor(theme.accent)
          }
        }
        .padding(EdgeInsets(top: 6, leading: theme.margin, bottom: 6, trailing: 4))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
          isActive ? theme.buttonIdle : phase == .hovered ? theme.buttonHover : .clear)
      }
      Button(
        "X", id: WidgetID("session-close:\(session.sessionId.uuidString)"),
        fontScale: theme.smallScale,
        padding: EdgeInsets(top: 2, leading: 6, bottom: 2, trailing: 6)
      ) { store.closeSession(session.sessionId) }
    }
    .padding(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 4))
  }
}

private struct DirectoryPalette: Block {
  let store: ScribeMacStore
  let theme: MacTheme
  let required: Bool

  @MainActor var body: some Block {
    VStack(spacing: 10, alignment: .leading) {
      if required {
        Text("Choose a project directory").fontScale(theme.textScale).foregroundColor(theme.accent)
        WrappedText(
          text: "Scribe launched from /. Type a path and press Enter to start a session there.",
          theme: theme, color: theme.textSecondary)
      } else {
        Text("Change directory").fontScale(theme.textScale).foregroundColor(theme.accent)
        WrappedText(
          text: "Starts a new session in the chosen directory. Tab completes directory names.",
          theme: theme, color: theme.textSecondary)
      }
      HStack(spacing: 6) {
        Text("$ cd").fontScale(theme.textScale).foregroundColor(theme.green)
        TextField(
          required ? "/path/to/project" : "path",
          id: ScribeMacStore.directoryPaletteID,
          fontScale: theme.textScale,
          text: { store.directoryDraft },
          onChange: { store.updateDirectoryDraft($0) },
          onSubmit: { store.submitDirectory($0) }
        )
      }
      if !store.directoryError.isEmpty {
        Text(sanitizeASCII(store.directoryError))
          .fontScale(theme.smallScale)
          .foregroundColor(theme.errorText)
      }
      if !store.directoryMatches.isEmpty {
        VStack(spacing: 2, alignment: .leading) {
          Text("Matches")
            .fontScale(theme.smallScale)
            .foregroundColor(theme.textSecondary)
          for match in store.directoryMatches.prefix(8) {
            Text(sanitizeASCII(match))
              .fontScale(theme.smallScale)
              .foregroundColor(theme.textPrimary)
          }
          if store.directoryMatches.count > 8 {
            Text("+\(store.directoryMatches.count - 8) more")
              .fontScale(theme.smallScale)
              .foregroundColor(theme.textSecondary)
          }
        }
      }
      if !required {
        HStack(spacing: 8) {
          Button("Cancel", id: WidgetID("directory-cancel"), fontScale: theme.smallScale) {
            store.closeDirectoryPicker()
          }
        }
      }
      if required {
        Spacer()
      }
    }
    .padding(theme.margin)
    .frame(maxWidth: required ? .infinity : 640, maxHeight: required ? .infinity : nil, alignment: .topLeading)
    .background(theme.headerBackground)
    .border(theme.border)
  }
}

private struct ReadyLayout: Block {
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

private struct TranscriptView: Block {
  let session: SessionController
  let theme: MacTheme

  @MainActor var body: some Block {
    let rows: [LazyVStack.Row]
    if session.transcript.isEmpty {
      rows = [LazyVStack.Row(
        id: WidgetID("transcript-empty"),
        content: VStack(spacing: 8, alignment: .leading) {
          Text("Ready").fontScale(theme.textScale).foregroundColor(theme.accent)
          WrappedText(
            text: "Ask Scribe to inspect, explain, or change the current project.",
            theme: theme, color: theme.textSecondary)
        }
        .padding(theme.panelPadding)
        .frame(maxWidth: .infinity, alignment: .topLeading)
      )]
    } else {
      rows = session.transcript.map { item in
        LazyVStack.Row(
          id: item.layoutID,
          content: TranscriptItemBlock(item: item, theme: theme)
            .padding(EdgeInsets(
              top: theme.spacing / 2, leading: theme.margin,
              bottom: theme.spacing / 2, trailing: theme.margin))
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

private struct BottomChrome: Block {
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

private struct ComposerBar: Block {
  let session: SessionController
  let theme: MacTheme

  @MainActor var body: some Block {
    HStack(spacing: 8) {
      TextField(
        session.isRunning ? "Queue a message..." : "Message Scribe",
        id: ScribeMacStore.composerID,
        fontScale: theme.textScale,
        text: { session.draft },
        onChange: { session.draft = sanitizeASCII($0.replacingOccurrences(of: "\n", with: " ")) },
        onSubmit: { session.submit($0) }
      )
      if session.isRunning {
        Button(
          "Queue", id: WidgetID("queue"), fontScale: theme.textScale,
          pressedColor: theme.accent
        ) { session.submit() }
        Button(
          "Stop", id: WidgetID("stop"), fontScale: theme.textScale,
          pressedColor: theme.red
        ) { session.stop() }
      } else {
        Button(
          "Send", id: WidgetID("send"), fontScale: theme.textScale,
          pressedColor: theme.accent
        ) { session.submit() }
      }
    }
    .padding(theme.margin)
    .frame(maxWidth: .infinity, alignment: .topLeading)
    .background(theme.composerBackground)
    .border(theme.border)
  }
}

private struct QueuedTray: Block {
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

private struct StatusBar: Block {
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
    .frame(height: theme.statusHeight, alignment: .topLeading)
    .frame(maxWidth: .infinity, alignment: .topLeading)
    .background(theme.statusBackground)
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
