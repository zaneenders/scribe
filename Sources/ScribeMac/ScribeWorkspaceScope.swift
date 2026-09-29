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
    return BlockContextBridge(content: content,
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
      },
      finish: { context in
        store.finishDirectoryPaletteInput(context)
      })
      .onCommand(ScribeCommandPickerCommand.toggle) {
        guard store.showDirectoryPicker, store.renamingSessionID == nil else { return .ignored }
        store.tabCompleteDirectory()
        return .handled
      }
      .onCommand(ScribeComposerCommand.submit) {
        guard !store.showDirectoryPicker, store.renamingSessionID == nil,
          store.active?.commandPicker == nil, ScribeMacStore.composerFocus.isEditing
        else { return .ignored }
        store.active?.submit()
        return .handled
      }
  }

}
