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
        CommandPickerInput(session: session) {
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
      ComposerRow(spacing: 8) {
        GrowingTextField(
          session.isRunning ? "Queue a message..." : "Message Scribe",
          id: ScribeMacStore.composerID,
          fontScale: theme.textScale,
          text: { session.draft },
          onChange: { session.updateDraft($0) },
          onNewline: { session.insertComposerNewline() }
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
  let session: SessionController
  let content: Content

  init(session: SessionController, @BlockBuilder content: () -> Content) {
    self.session = session
    self.content = content()
  }

  @MainActor var expandsHorizontally: Bool { BlockEngine.expandsHorizontally(content) }
  @MainActor var expandsVertically: Bool { BlockEngine.expandsVertically(content) }

  @MainActor func sizeThatFits(_ proposal: Size, context: RenderContext) -> Size {
    BlockEngine.measure(content, proposal: proposal, context: context)
  }

  @MainActor func draw(into drawList: inout DrawList, in rect: Rect, context: RenderContext) {
    for command in context.input.commands {
      switch command {
      case ScribeCommandPickerCommand.previous, ScribeTerminalCommand.lineUp:
        session.moveCommandCursor(by: -1)
      case ScribeCommandPickerCommand.next, ScribeTerminalCommand.lineDown:
        session.moveCommandCursor(by: 1)
      case ScribeTerminalCommand.complete:
        session.toggleCommandBoundary()
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

/// Measures the fixed composer controls first, then proposes only the remaining
/// width to the text field. Chroma's `HStack` measures every child with the full
/// row width, which made the field wrap as though the send area did not exist.
private struct ComposerRow<Input: Block, Controls: Block>: PrimitiveBlock {
  let spacing: Float
  let input: Input
  let controls: Controls

  init(
    spacing: Float,
    @BlockBuilder input: () -> Input,
    @BlockBuilder controls: () -> Controls
  ) {
    self.spacing = spacing
    self.input = input()
    self.controls = controls()
  }

  @MainActor var expandsHorizontally: Bool { true }

  @MainActor func sizeThatFits(_ proposal: Size, context: RenderContext) -> Size {
    let sizes = measuredSizes(for: proposal, context: context)
    return Size(
      width: proposal.width,
      height: max(sizes.input.height, sizes.controls.height))
  }

  @MainActor func draw(into drawList: inout DrawList, in rect: Rect, context: RenderContext) {
    let sizes = measuredSizes(for: rect.size, context: context)
    let inputRect = Rect(
      x: rect.minX,
      y: rect.maxY - sizes.input.height,
      width: sizes.input.width,
      height: sizes.input.height)
    let controlsRect = Rect(
      x: rect.maxX - sizes.controls.width,
      y: rect.maxY - sizes.controls.height,
      width: sizes.controls.width,
      height: sizes.controls.height)

    BlockEngine.draw(input, into: &drawList, in: inputRect, context: context)
    BlockEngine.draw(controls, into: &drawList, in: controlsRect, context: context)
  }

  @MainActor private func measuredSizes(
    for proposal: Size, context: RenderContext
  ) -> (input: Size, controls: Size) {
    let controlsSize = BlockEngine.measure(controls, proposal: proposal, context: context)
    let inputWidth = max(0, proposal.width - controlsSize.width - spacing)
    let inputSize = BlockEngine.measure(
      input,
      proposal: Size(width: inputWidth, height: proposal.height),
      context: context)
    return (
      input: Size(width: inputWidth, height: inputSize.height),
      controls: controlsSize
    )
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
