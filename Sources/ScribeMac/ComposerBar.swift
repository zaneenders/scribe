import Chroma
import Foundation

/// Everything below the transcript: the queued-message tray (when non-empty),
/// the composer, and the status bar.
struct BottomChrome: Block {
  let store: ScribeMacStore
  let session: SessionController
  let theme: MacTheme

  @MainActor var body: some Block {
    VStack(spacing: 0) {
      if !session.queuedTexts.isEmpty {
        QueuedTray(session: session, theme: theme)
      }
      if let picker = session.commandPicker {
        CommandPickerInput(store: store, session: session) {
          VStack(spacing: 0) {
            CommandPickerBar(session: session, picker: picker, theme: theme)
            StatusBar(store: store, session: session, theme: theme)
          }
        }
      } else {
        if store.showModelPicker {
          BottomModelPicker(store: store, session: session, theme: theme)
        }
        ComposerBar(store: store, session: session, theme: theme)
        StatusBar(store: store, session: session, theme: theme)
      }
    }
    .sizing(x: .grow)
  }
}

struct ComposerBar: Block {
  let store: ScribeMacStore
  let session: SessionController
  let theme: MacTheme

  @MainActor var body: some Block {
    VStack(spacing: 6) {
      TrailingControlsRow(spacing: 8) {
        GrowingTextField(
          session.isRunning ? "Queue a message..." : "Message Scribe",
          id: ScribeMacStore.composerID,
          fontScale: theme.textScale,
          text: { session.draft },
          onChange: { if session.draft != $0 { session.updateDraft($0) } },
          onNewline: { session.insertComposerNewline() },
          onEndEditing: {
            guard session.isRunning else { return .ignored }
            session.stop()
            return .handled
          },
          onTextEvent: { event, text in
            guard event == .moveCaretUp || event == .moveCaretDown else { return nil }
            if session.draft != text { session.updateDraft(text) }
            let recalled = event == .moveCaretUp
              ? session.recallPreviousPrompt() : session.recallNextPrompt()
            return recalled ? session.draft : nil
          }
        )
      } controls: {
        if session.isRunning {
          HStack(spacing: 6) {
            Button(
              "Queue ↵", id: WidgetID("queue"), fontScale: theme.textScale,
              style: theme.buttonStyle(pressedColor: theme.accent)
            ) { session.submit() }
            Button(
              "Stop ■", id: WidgetID("stop"), fontScale: theme.textScale,
              style: theme.buttonStyle(pressedColor: theme.red)
            ) { session.stop() }
          }
        } else {
          Button(
            "Send ↵", id: WidgetID("send"), fontScale: theme.textScale,
            style: theme.buttonStyle(pressedColor: theme.accent)
          ) { session.submit() }
        }
      }

      HStack(spacing: 6) {
        if !session.isRunning {
          Interactive(id: WidgetID("model-picker-toggle"), action: { store.toggleModelPicker() }) { phase in
            HStack(spacing: 5) {
              Text(sanitizeASCII(session.profileName))
                .fontScale(theme.smallScale)
                .foregroundColor(phase == .hovered ? theme.accent : theme.textPrimary)
              Text(store.showModelPicker ? "▼" : "▲")
                .fontScale(theme.smallScale)
                .foregroundColor(theme.textSecondary)
            }
            .padding(EdgeInsets(top: 3, leading: 10, bottom: 3, trailing: 10))
            .background(phase == .hovered ? theme.buttonHover : theme.buttonIdle)
            .border(theme.border)
          }
          Button(
            "TLDR", id: WidgetID("tldr"), fontScale: theme.smallScale,
            style: theme.buttonStyle(pressedColor: theme.purple),
            padding: EdgeInsets(top: 3, leading: 10, bottom: 3, trailing: 10)
          ) { session.openCommandPicker(.tldr) }
          Button(
            "Fork", id: WidgetID("fork"), fontScale: theme.smallScale,
            style: theme.buttonStyle(pressedColor: theme.orange),
            padding: EdgeInsets(top: 3, leading: 10, bottom: 3, trailing: 10)
          ) { session.openCommandPicker(.fork) }
        }
        Spacer()
        Text(session.isRunning ? "⌘↵ queue  ·  Esc stop" : "⌘↵ send  ·  Shift↵ newline")
          .fontScale(theme.smallScale)
          .foregroundColor(theme.textSecondary)
      }
    }
    .padding(theme.margin)
    .sizing(x: .grow)
    .background(theme.composerBackground)
    .border(theme.border)
  }
}

struct BottomModelPicker: Block {
  let store: ScribeMacStore
  let session: SessionController
  let theme: MacTheme

  @MainActor var body: some Block {
    VStack(spacing: 0) {
      for (_, profile) in store.profileCatalog.enumerated() {
        let isActive = profile.name == session.profileName
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
          .sizing(y: .fixed(34))
          .sizing(x: .grow)
          .background(
            phase == .hovered
              ? theme.buttonHover
              : isActive ? theme.buttonIdle : theme.panelBackground)
        }
      }
    }
    .sizing(x: .grow)
    .background(theme.headerBackground)
    .border(theme.border)
  }
}

private struct CommandPickerInput<Content: Block>: PrimitiveBlock {
  let store: ScribeMacStore
  let session: SessionController
  let content: Content

  init(store: ScribeMacStore, session: SessionController, @BlockBuilder content: () -> Content) {
    self.store = store
    self.session = session
    self.content = content()
  }

  @MainActor var expandsHorizontally: Bool { BlockEngine.expandsHorizontally(content) }
  @MainActor var expandsVertically: Bool { BlockEngine.expandsVertically(content) }

  @MainActor func sizeThatFits(_ proposal: Size, context: RenderContext) -> Size {
    BlockEngine.measure(content, proposal: proposal, context: context)
  }

  @MainActor func draw(into drawList: inout DrawList, in rect: Rect, context: RenderContext) {
    if !store.showDirectoryPicker, store.renamingSessionID == nil {
      for command in context.input.commands {
        switch command {
        case ScribeCommandPickerCommand.previous:
          session.moveCommandCursor(by: -1)
        case ScribeCommandPickerCommand.next:
          session.moveCommandCursor(by: 1)
        case ScribeCommandPickerCommand.toggle:
          session.toggleCommandBoundary()
        case .action(.activate):
          session.confirmCommandPicker()
        default:
          break
        }
      }
      for event in context.input.textEvents {
        switch event {
        case .submit:
          session.confirmCommandPicker()
        case .endEditing:
          session.cancelCommandPicker()
        default:
          break
        }
      }
    }
    BlockEngine.draw(content, into: &drawList, in: rect, context: context)
  }
}

struct CommandPickerBar: Block {
  let session: SessionController
  let picker: SessionController.CommandPickerState
  let theme: MacTheme

  @MainActor var body: some Block {
    HStack(spacing: 0) {
      Text("[\(picker.command.rawValue.uppercased())] ")
        .fontScale(theme.smallScale)
        .foregroundColor(picker.command == .tldr ? theme.purple : theme.orange)
      if picker.command == .fork {
        Text("msg \(picker.startBoundary) / \(picker.messageCount)")
          .fontScale(theme.smallScale)
          .foregroundColor(theme.textPrimary)
      } else {
        boundaryLabel("start", value: picker.startBoundary, active: !picker.activeIsEnd)
        Text(" · ")
          .fontScale(theme.smallScale).foregroundColor(theme.textSecondary)
        boundaryLabel("end", value: picker.endBoundary, active: picker.activeIsEnd)
        Text(" of \(picker.messageCount)")
          .fontScale(theme.smallScale).foregroundColor(theme.textPrimary)
      }
      Spacer()
      Text(commandHint)
        .fontScale(theme.smallScale)
        .foregroundColor(theme.textSecondary)
    }
    .padding(EdgeInsets(top: 7, leading: theme.margin, bottom: 7, trailing: theme.margin))
    .sizing(x: .grow)
    .background(theme.statusBackground)
    .border(theme.border)
  }

  @MainActor private func boundaryLabel(_ label: String, value: Int, active: Bool) -> some Block {
    HStack(spacing: 0) {
      Text("\(label) ")
        .fontScale(theme.smallScale).foregroundColor(theme.textPrimary)
      Text("\(value)")
        .fontScale(theme.smallScale)
        .foregroundColor(active ? theme.yellow : theme.textPrimary)
    }
  }

  @MainActor private var commandHint: String {
    if session.isRunningCommand { return "working..." }
    return picker.command == .tldr
      ? "f/j move · Tab switch · Enter confirm · Esc cancel"
      : "f/j move · Enter confirm · Esc cancel"
  }
}


struct QueuedTray: Block {
  let session: SessionController
  let theme: MacTheme

  @MainActor var body: some Block {
    let queued = session.queuedTexts
    return VStack(spacing: 4) {
      HStack(spacing: 8) {
        Text("QUEUED (\(queued.count)) · sent in order after each turn")
          .fontScale(theme.smallScale)
          .foregroundColor(theme.yellow)
        Spacer()
        Button(
          "Send next", id: WidgetID("force-send-queue"), fontScale: theme.smallScale,
          style: theme.buttonStyle(pressedColor: theme.accent),
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
    .sizing(x: .grow)
    .background(theme.statusBackground)
    .border(theme.border)
  }

  private func queuePreview(_ text: String, limit: Int = 100) -> String {
    let flat = sanitizeASCII(text.replacingOccurrences(of: "\n", with: " "))
    guard flat.count > limit else { return flat }
    return String(flat.prefix(limit - 3)) + "..."
  }
}
