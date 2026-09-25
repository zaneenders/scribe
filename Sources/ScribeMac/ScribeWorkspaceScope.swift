import Chroma
import Foundation

public struct ScribeWorkspaceScope<Content: Block>: Block {
  let content: Content
  let workspace: ScribeWorkspace

  public init(content: Content, workspace: ScribeWorkspace) {
    self.content = content
    self.workspace = workspace
  }

  @MainActor public var body: some Block {
    let store = workspace.store
    store.start()
    return RenderContextBridge(content: content,
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

}
