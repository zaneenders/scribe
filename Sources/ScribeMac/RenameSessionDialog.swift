import Chroma
import Foundation

/// App-owned, backend-independent modal overlay for assigning a custom session name.
struct RenameSessionDialog: Block {
  let store: ScribeMacStore
  let sessionID: UUID
  let theme: MacTheme

  @MainActor var body: some Block {
    RenameSessionInput(store: store) {
      ZStack {
        // The full-window scrim owns the background hit target so clicks do not
        // leak through to session rows while the dialog is open.
        Interactive(
          id: WidgetID("rename-session-scrim"),
          action: { store.cancelSessionRename() }
        ) { _ in
          VStack(spacing: 0) {
            Spacer()
            HStack(spacing: 0) { Spacer() }
            Spacer()
          }
          .sizing(x: .grow, y: .grow)
          .background(Color(r: 0.02, g: 0.025, b: 0.04, a: 0.82))
        }

        HStack(spacing: 0) {
          Spacer()
          VStack(spacing: 12) {
            HStack(spacing: 8) {
              Text("✎")
                .fontScale(theme.textScale)
                .foregroundColor(theme.green)
              Text("RENAME SESSION")
                .fontScale(theme.smallScale)
                .foregroundColor(theme.green)
              Spacer()
            }
            WrappedText(
              text: "Enter a custom name. Leave it blank to restore the session hash.",
              theme: theme, color: theme.textSecondary, scale: theme.smallScale)
            TextField(
              String(sessionID.uuidString.prefix(8)).uppercased(),
              id: ScribeMacStore.renameSessionFieldID,
              fontScale: theme.textScale,
              text: { store.renameSessionDraft },
              onChange: { store.updateRenameSessionDraft($0) },
              onSubmit: { _ in store.submitSessionRename() }
            )
            HStack(spacing: 8) {
              Spacer()
              Button(
                "Cancel", id: WidgetID("rename-session-cancel"), fontScale: theme.smallScale
              ) { store.cancelSessionRename() }
              Button(
                "Rename", id: WidgetID("rename-session-submit"), fontScale: theme.smallScale,
                style: theme.buttonStyle(pressedColor: theme.green)
              ) { store.submitSessionRename() }
            }
          }
          .padding(EdgeInsets(top: 18, leading: 20, bottom: 18, trailing: 20))
          .sizing(x: .fixed(460), y: .fit)
          .background(theme.headerBackground)
          .border(theme.green, width: 1)
          Spacer()
        }
        .padding(EdgeInsets(top: 120, leading: 0, bottom: 0, trailing: 0))
        .sizing(x: .grow, y: .grow)
      }
      .sizing(x: .grow, y: .grow)
    }
  }
}

/// Handles Chroma's backend-neutral editing commands while the rename modal is open.
private struct RenameSessionInput<Content: Block>: PrimitiveBlock {
  let store: ScribeMacStore
  let content: Content

  init(store: ScribeMacStore, @BlockBuilder content: () -> Content) {
    self.store = store
    self.content = content()
  }

  @MainActor var expandsHorizontally: Bool { BlockEngine.expandsHorizontally(content) }
  @MainActor var expandsVertically: Bool { BlockEngine.expandsVertically(content) }

  @MainActor func sizeThatFits(_ proposal: Size, context: RenderContext) -> Size {
    BlockEngine.measure(content, proposal: proposal, context: context)
  }

  @MainActor func draw(into drawList: inout DrawList, in rect: Rect, context: RenderContext) {
    if context.input.textEvents.contains(.endEditing) {
      store.cancelSessionRename()
    }
    BlockEngine.draw(content, into: &drawList, in: rect, context: context)
  }
}
