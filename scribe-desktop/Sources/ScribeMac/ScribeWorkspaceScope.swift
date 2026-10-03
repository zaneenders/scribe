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
    return BlockContextBridge(
      content: content,
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
        if context.input.commands.contains(where: {
          if case .navigation = $0 { return true }
          return false
        }) {
          context.requestRedraw()
        }
      }
    )
    .onCommand(.navigation(.stepIn)) {
      if let context = ScribeBlockContext.current,
        context.navigationBreadcrumb.last == "Transcript",
        context.navigationSelectionIsGroup,
        let session = store.active,
        !session.transcript.isEmpty
      {
        session.scroll.scrollToBottom()
        session.lastTranscriptFocus.focus()
      }
      return .ignored
    }
    .onCommand(.navigation(.sectionLeft)) {
      if ScribeMacStore.composerFocus.isEditing { ScribeBlockContext.current?.endEditing() }
      return .ignored
    }
    .onCommand(.navigation(.sectionUp)) {
      if ScribeMacStore.composerFocus.isEditing { ScribeBlockContext.current?.endEditing() }
      return .ignored
    }
    .onCommand(.navigation(.sectionDown)) {
      if ScribeMacStore.composerFocus.isEditing { ScribeBlockContext.current?.endEditing() }
      return .ignored
    }
    .onCommand(.navigation(.sectionRight)) {
      if ScribeMacStore.composerFocus.isEditing { ScribeBlockContext.current?.endEditing() }
      return .ignored
    }
    .onCommand(ScribeCommandPickerCommand.previous) {
      guard !store.showDirectoryPicker, store.renamingSessionID == nil,
        let session = store.active, session.commandPicker != nil
      else { return .ignored }
      session.moveCommandCursor(by: -1)
      return .handled
    }
    .onCommand(ScribeCommandPickerCommand.next) {
      guard !store.showDirectoryPicker, store.renamingSessionID == nil,
        let session = store.active, session.commandPicker != nil
      else { return .ignored }
      session.moveCommandCursor(by: 1)
      return .handled
    }
    .onCommand(ScribeCommandPickerCommand.toggle) {
      if store.showDirectoryPicker, store.renamingSessionID == nil {
        store.tabCompleteDirectory()
        return .handled
      }
      guard store.renamingSessionID == nil, let session = store.active,
        session.commandPicker != nil
      else { return .ignored }
      session.toggleCommandBoundary()
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
