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
                isActive
                  ? theme.accent
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
            phase == .hovered
              ? theme.buttonHover
              : isActive ? theme.buttonIdle : theme.panelBackground)
        }
      }
    }
    .frame(maxWidth: 300, alignment: .leading)
    .background(theme.headerBackground)
    .border(theme.border)
  }
}
