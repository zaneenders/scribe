import ChromaTesting
import Testing

@testable import Chroma
@testable import ScribeBlocks

struct TextDisclosureTests {
  @Test @MainActor func focusedLongPromptCanExpandAndCollapse() throws {
    let target = FocusTarget()
    let controller = ScrollViewController()
    var item = SessionController.TranscriptItem(
      kind: .user, title: "You", text: String(repeating: "implementation step\n", count: 100))
    let renderer = HeadlessHost(size: Size(width: 800, height: 4_000))
    defer { renderer.close() }

    for label in ["Show full text", "Hide text", "Show full text"] {
      renderer.content = ScrollView(controller: controller, rows: [
        .init(id: item.layoutID, content: NavigableTranscriptItem(
          content: TranscriptItemBlock(item: item, theme: MacTheme(), toggleText: {
            item.toggleTextDisclosure()
          }))
          .focusTarget(target)
          .sizing(x: .grow))
      ])
      renderer.render()
      target.focus()
      let frame = renderer.render()
      #expect(target.isFocused)
      let position = try #require(frame.commands.compactMap { command -> Point? in
        guard case .text(let position, let text, _, _) = command, text == label else { return nil }
        return position
      }.first)
      let expanded = item.isTextExpanded
      let point = Point(x: position.x + 4, y: position.y + 4)
      renderer.render(input: InputState(pointerPosition: point, pointerPressed: true))
      renderer.render(input: InputState(pointerPosition: point, pointerReleased: true))
      #expect(item.isTextExpanded != expanded)
    }
    #expect(item.layoutRevision == 3)
  }

  @Test @MainActor func disclosureButtonStaysInsideCard() {
    for width: Float in [320, 800] {
      var item = SessionController.TranscriptItem(
        kind: .user, title: "You", text: String(repeating: "log line\n", count: 20))
      for expanded in [false, true] {
        if expanded { item.toggleTextDisclosure() }
        let block = TranscriptItemBlock(item: item, theme: MacTheme())
        let interaction = Interaction()
        interaction.beginFrame(input: InputState())
        let context = BlockContext(interaction: interaction)
        let size = BlockEngine.measure(
          block, proposal: Size(width: width, height: 10_000), context: context)
        var list = DrawList()
        BlockEngine.draw(
          block, into: &list,
          in: Rect(x: 0, y: 0, width: width, height: size.height), context: context)
        let label = expanded ? "Hide text" : "Show full text"
        var buttons = 0
        for command in list.commands {
          if case .text(let position, let text, _, let scale) = command, text == label {
            buttons += 1
            #expect(position.x >= 0)
            #expect(position.x + Float(text.count) * context.fontMetrics.cellAdvance * scale <= width)
            #expect(position.y >= 0 && position.y < size.height)
          }
        }
        interaction.endFrame()
        #expect(buttons == 1)
      }
    }
  }

  @Test func largeUserTextIsCollapsedWithoutChangingSource() {
    let source = String(repeating: "log line\r\n", count: 581)
    var item = SessionController.TranscriptItem(kind: .user, title: "You", text: source)
    #expect(item.isTextCollapsed)
    #expect(item.displayText.count < 300)
    #expect(item.selectionBody == item.displayText)
    let collapsedID = item.layoutID
    let selectionID = item.selectionID
    item.toggleTextDisclosure()
    #expect(!item.isTextCollapsed)
    #expect(item.displayText == source)
    #expect(item.layoutID != collapsedID)
    #expect(item.selectionID == selectionID)
    item.toggleTextDisclosure()
    #expect(item.isTextCollapsed)
    #expect(item.text == source)
    #expect(item.layoutRevision == 2)
  }

  @Test func thresholdsAndRoles() {
    #expect(
      !SessionController.TranscriptItem(kind: .user, title: "", text: String(repeating: "x", count: 1000)).isCollapsible
    )
    #expect(
      SessionController.TranscriptItem(kind: .user, title: "", text: String(repeating: "x", count: 1001)).isCollapsible)
    #expect(
      !SessionController.TranscriptItem(kind: .user, title: "", text: String(repeating: "\n", count: 9)).isCollapsible)
    #expect(
      SessionController.TranscriptItem(kind: .user, title: "", text: String(repeating: "\n", count: 10)).isCollapsible)
    for kind in [SessionController.ItemKind.answer, .reasoning, .tool] {
      var item = SessionController.TranscriptItem(kind: kind, title: "", text: String(repeating: "x", count: 2000))
      item.toggleTextDisclosure()
      #expect(!item.isCollapsible)
      #expect(item.displayText == item.text)
      #expect(item.layoutRevision == 0)
    }
  }
}
