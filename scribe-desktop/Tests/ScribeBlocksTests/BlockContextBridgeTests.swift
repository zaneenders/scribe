@testable import Chroma
import Testing

@testable import ScribeBlocks

@MainActor
struct BlockContextBridgeTests {
  @Test func paintingDoesNotRepeatInputPreparation() {
    let context = BlockContext(interaction: Interaction())
    let previous = BlockContext(interaction: Interaction())
    ScribeBlockContext.current = previous
    defer { ScribeBlockContext.current = nil }
    var preparations = 0
    var completions = 0
    let bridge = BlockContextBridge(
      content: Text("Prepared"),
      prepare: { _ in preparations += 1 },
      finish: { _ in completions += 1 })
    let resolved = BlockEngine.prepare(bridge, context: context)
    let rect = Rect(x: 0, y: 0, width: 200, height: 40)
    _ = resolved.sizeThatFits(rect.size)
    #expect(ScribeBlockContext.current?.interaction === previous.interaction)
    resolved.register(in: rect)
    #expect(preparations == 1)
    #expect(completions == 1)
    #expect(ScribeBlockContext.current?.interaction === previous.interaction)
    var list = DrawList()
    resolved.paint(into: &list, in: rect)
    resolved.paint(into: &list, in: rect)
    #expect(preparations == 1)
    #expect(completions == 1)
    #expect(ScribeBlockContext.current?.interaction === previous.interaction)
    #expect(!list.commands.isEmpty)
  }

  @Test func markdownRegistersSelectionLayoutWithoutPainting() {
    MarkdownLayoutRegistry.clear()
    defer { MarkdownLayoutRegistry.clear() }
    let context = BlockContext(interaction: Interaction())
    let block = MarkdownText(
      markdown: "Registered text", theme: MacTheme(), baseColor: .white,
      itemID: "registration-test")
    let rect = Rect(x: 0, y: 0, width: 200, height: 40)
    let resolved = BlockEngine.prepare(block, context: context)
    resolved.register(in: rect)
    #expect(MarkdownLayoutRegistry.layout(for: "registration-test") != nil)
    MarkdownLayoutRegistry.clear()
    var list = DrawList()
    resolved.paint(into: &list, in: rect)
    #expect(MarkdownLayoutRegistry.layout(for: "registration-test") == nil)
    #expect(!list.commands.isEmpty)
  }
}
