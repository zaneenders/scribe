#if os(macOS)
import AppKit
@testable import Chroma
import MetalKit
@testable import MetalBackend
@testable import ScribeBlocks
import Testing

@MainActor
struct TranscriptClipboardTests {
  @Test func commandCopyWritesSelectedTranscriptToPasteboard() throws {
    let pasteboard = NSPasteboard.general
    let saved = (pasteboard.pasteboardItems ?? []).map { item in
      item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
    }
    defer {
      pasteboard.clearContents()
      pasteboard.writeObjects(
        saved.map { values in
          let item = NSPasteboardItem()
          for (type, data) in values { item.setData(data, forType: type) }
          return item
        })
      SelectionManager.shared.clear()
      MarkdownLayoutRegistry.clear()
      TranscriptSelectionDocumentRegistry.setEntries(ownerID: UUID(), [])
    }
    let renderer = try MacOSHost(size: Size(width: 400, height: 200))
    renderer.content = BlockContextBridge(
      content: MarkdownText(
        markdown: "Two details will narrow this down:", theme: MacTheme(),
        baseColor: .white, scale: 1, itemID: "clipboard-test"),
      prepare: { context in
        context.setCopyTextProvider {
          SelectionManager.shared.copyText(isTranscriptVisible: true)
        }
      }
    ).keyBindings(ScribeBlock.keyBindings)
    let view = MTKView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
    _ = renderer.runtime.render(viewport: Size(width: 400, height: 200), input: InputState(), onChange: {})
    TranscriptSelectionDocumentRegistry.setEntries(
      ownerID: UUID(),
      [
        .init(
          id: "clipboard-test",
          linesForColumns: { columns in
            layoutPlainText("Two details will narrow this down:", columns: columns, color: .white)
          })
      ])
    #expect(SelectionManager.shared.selectAll(isTranscriptVisible: true))
    pasteboard.clearContents()
    pasteboard.setString("previous clipboard", forType: .string)

    let inputView = ChromaInputView(frame: view.frame, device: MTLCreateSystemDefaultDevice())
    inputView.onKey = { renderer.handleKey($0, frameInput: InputState()) }
    let event = try #require(
      NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
        windowNumber: 0, context: nil, characters: "c", charactersIgnoringModifiers: "c",
        isARepeat: false, keyCode: 8))
    inputView.keyDown(with: event)

    #expect(pasteboard.string(forType: .string) == "Two details will narrow this down:")
  }
}
#endif
