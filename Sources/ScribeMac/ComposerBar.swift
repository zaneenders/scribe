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
      ComposerBar(session: session, theme: theme)
      StatusBar(store: store, session: session, theme: theme)
    }
    .sizing(x: .grow)
  }
}

struct ComposerBar: Block {
  let session: SessionController
  let theme: MacTheme

  @MainActor var body: some Block {
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
      VStack(spacing: 4) {
        if session.isRunning {
          HStack(spacing: 6) {
            Button(
              "Queue", id: WidgetID("queue"), fontScale: theme.textScale,
              style: theme.buttonStyle(pressedColor: theme.accent)
            ) { session.submit() }
            Button(
              "Stop", id: WidgetID("stop"), fontScale: theme.textScale,
              style: theme.buttonStyle(pressedColor: theme.red)
            ) { session.stop() }
          }
        } else {
          Button(
            "Send", id: WidgetID("send"), fontScale: theme.textScale,
            style: theme.buttonStyle(pressedColor: theme.accent)
          ) { session.submit() }
        }
        Text(session.isRunning ? "Cmd+Return queue | Esc stop" : "Cmd+Return send")
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
