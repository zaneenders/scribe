import Chroma
import MetalBackend

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
    store.applyPendingFocus()
    return VStack(spacing: 0, alignment: .leading) {
      header
      switch store.phase {
      case .starting:
        VStack(spacing: 12) {
          Spacer()
          Text("Starting Scribe...").fontScale(theme.textScale).foregroundColor(theme.textSecondary)
          Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      case .failed(let message):
        VStack(spacing: 14, alignment: .leading) {
          Text("Could not start Scribe").fontScale(theme.textScale).foregroundColor(theme.errorText)
          WrappedText(text: message, theme: theme, color: theme.textPrimary)
          HStack(spacing: 8) {
            Button("New session", id: WidgetID("retry-new")) { store.newSession() }
            Button("Resume latest", id: WidgetID("retry-resume")) { store.resumeLatest() }
          }
          Spacer()
        }
        .padding(theme.margin)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      case .ready:
        // A switch branch is represented as one TupleBlock child by BlockBuilder.
        // Give the ready-state regions their own stack so they are laid out
        // vertically instead of all being drawn into the same rectangle.
        VStack(spacing: 0, alignment: .leading) {
          transcript
          composer
          status
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      }
    }
    .background(theme.background)
  }

  @MainActor private var header: some Block {
    HStack(spacing: 10) {
      Text("SCRIBE").fontScale(theme.textScale).foregroundColor(theme.accent)
      Text("\(sanitizeASCII(store.profileName)) / \(sanitizeASCII(store.modelName))")
        .fontScale(theme.smallScale).foregroundColor(theme.textSecondary)
      Spacer()
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

  @MainActor private var transcript: some Block {
    ScrollView(
      id: WidgetID("transcript"), sticksToBottom: true, controller: store.transcriptScroll
    ) {
      if store.transcript.isEmpty {
        VStack(spacing: 8, alignment: .leading) {
          Text("Ready").fontScale(theme.textScale).foregroundColor(theme.accent)
          WrappedText(
            text: "Ask Scribe to inspect, explain, or change the current project.",
            theme: theme, color: theme.textSecondary)
        }
        .padding(theme.panelPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      for item in store.transcript {
        TranscriptItemBlock(item: item, theme: theme)
          .padding(EdgeInsets(
            top: theme.spacing / 2, leading: theme.margin,
            bottom: theme.spacing / 2, trailing: theme.margin))
          .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(theme.panelBackground)
  }

  @MainActor private var composer: some Block {
    HStack(spacing: 8) {
      TextField(
        store.isRunning ? "Scribe is working..." : "Message Scribe",
        id: ScribeMacStore.composerID,
        fontScale: theme.textScale,
        text: { store.draft },
        onChange: { store.draft = sanitizeASCII($0.replacingOccurrences(of: "\n", with: " ")) },
        onSubmit: { store.submit($0) }
      )
      if store.isRunning {
        Button("Stop", id: WidgetID("stop"), pressedColor: theme.red) { store.stop() }
      } else {
        Button("Send", id: WidgetID("send"), pressedColor: theme.accent) { store.submit() }
      }
    }
    .padding(theme.margin)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(theme.composerBackground)
    .border(theme.border)
  }

  @MainActor private var status: some Block {
    HStack(spacing: 10) {
      Text(store.isRunning ? "WORKING" : "READY")
        .fontScale(theme.smallScale)
        .foregroundColor(store.isRunning ? theme.yellow : theme.green)
      Text(sanitizeASCII(store.workingDirectory))
        .fontScale(theme.smallScale).foregroundColor(theme.textSecondary)
      Spacer()
      if !store.usageText.isEmpty {
        Text(store.usageText).fontScale(theme.smallScale).foregroundColor(theme.textSecondary)
      }
    }
    .padding(EdgeInsets(top: 6, leading: theme.margin, bottom: 6, trailing: theme.margin))
    .frame(height: theme.statusHeight, alignment: .leading)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(theme.statusBackground)
  }
}

struct TranscriptItemBlock: Block {
  let item: ScribeMacStore.TranscriptItem
  let theme: MacTheme

  @MainActor var body: some Block {
    VStack(spacing: 6, alignment: .leading) {
      Text(label).fontScale(theme.smallScale).foregroundColor(labelColor)
      if item.text.isEmpty {
        Text(item.running ? "running..." : "(empty)")
          .fontScale(theme.smallScale).foregroundColor(theme.textSecondary)
      } else if item.kind == .answer || item.kind == .reasoning {
        MarkdownText(
          markdown: item.text, theme: theme, baseColor: bodyColor, scale: theme.textScale)
      } else {
        WrappedText(text: item.text, theme: theme, color: bodyColor, scale: theme.textScale)
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
