import Chroma
import ChromaTesting
import Testing

@testable import ScribeBlocks

@MainActor
struct SessionNavigationTests {
  @Test func keyboardCanMoveBetweenNamedRegionsAndActivateSession() {
    let session = FocusTarget()
    let composer = FocusTarget()
    var selections = 0
    let content = HStack {
      Group("Sessions") {
        ScribeSessionRow(
          id: "session", title: "Planning", subtitle: "model", isSelected: false,
          style: ScribeSessionRowStyle(
            foreground: .white, secondaryForeground: .white, selectedForeground: .white,
            activity: .white, selection: .clear, hover: .clear, border: .white, fontScale: 1),
          onSelect: { selections += 1 })
        .focusTarget(session)
      }
      .sizing(x: .fixed(250), y: .grow)
      Group("Conversation") {
        Group("Composer") {
          TextField(text: { "" }, onChange: { _ in }).focusTarget(composer)
        }
      }
      .sizing(x: .grow, y: .grow)
    }
    let ui = NavigationTestHost(content: content, size: Size(width: 600, height: 200), keyBindings: ScribeBlock.keyBindings)
    defer { ui.host.close() }
    composer.focus()
    ui.host.render()
    ui.press(KeyboardInput(chord: KeyChord("d", modifiers: .control)))
    #expect(!session.isFocused)
    ui.press("l")
    #expect(session.isFocused)
    ui.press(.enter)
    #expect(selections == 1)
    ui.press(KeyboardInput(chord: KeyChord(.tab)))
    #expect(composer.isFocused)
  }

  @Test func pickerKeysMoveStartThenEndWhileSidebarHasFocus() {
    let sidebar = FocusTarget()
    var picker = SessionController.CommandPickerState(
      command: .tldr, boundaries: [10, 20, 30, 40], startCursor: 2,
      endCursor: 3, activeIsEnd: false, messageCount: 40)
    let content = HStack {
      Group("Sessions") {
        Button("Session") {}.focusTarget(sidebar)
      }
      Group("Conversation") {
        Text("Transcript")
          .keyBindings(ScribeCommandPickerCommand.keyBindings)
        Text("Picker")
          .keyBindings(ScribeCommandPickerCommand.keyBindings)
      }
    }
    .keyBindings(ScribeCommandPickerCommand.keyBindings)
    .onCommand(ScribeCommandPickerCommand.previous) {
      picker.move(by: -1)
      return .handled
    }
    .onCommand(ScribeCommandPickerCommand.toggle) {
      picker.activeIsEnd.toggle()
      return .handled
    }
    let ui = NavigationTestHost(content: content, keyBindings: ScribeBlock.keyBindings)
    defer { ui.host.close() }
    sidebar.focus()
    ui.host.render()
    ui.press("f", "f")
    #expect(picker.startBoundary == 10)
    ui.press(KeyboardInput(chord: KeyChord(.tab)))
    #expect(picker.activeIsEnd)
    ui.press("f", "f")
    #expect(picker.startBoundary == 10)
    #expect(picker.endBoundary == 20)
  }

  @Test func movingTLDRStartThenEndKeepsStartFixed() {
    var picker = SessionController.CommandPickerState(
      command: .tldr, boundaries: [10, 20, 30, 40], startCursor: 2,
      endCursor: 3, activeIsEnd: false, messageCount: 40)
    picker.move(by: -2)
    #expect(picker.startBoundary == 10)
    #expect(picker.endBoundary == 40)
    picker.activeIsEnd = true
    picker.move(by: -1)
    #expect(picker.startBoundary == 10)
    #expect(picker.endBoundary == 30)
    picker.move(by: -1)
    #expect(picker.startBoundary == 10)
    #expect(picker.endBoundary == 20)
    picker.move(by: -1)
    #expect(picker.startBoundary == 10)
    #expect(picker.endBoundary == 20)
  }

  @Test func controlSectionUpLeavesEditingComposerForHistory() {
    let composer = FocusTarget()
    var context: BlockContext?
    let controller = ScrollViewController()
    let messages = (0..<12).map { _ in FocusTarget() }
    var cachedRows: [Int: ScrollView.Row] = [:]
    let content = DeferredBlock {
      BlockContextBridge(
        content: Group("Conversation") {
        VStack {
          ScrollView(
            "Transcript", sticksToBottom: true, controller: controller,
            rows: (0..<12).map { index in
              if let row = cachedRows[index] { return row }
              let row = ScrollView.Row(
                id: index,
                content: NavigableTranscriptItem(
                  content: TranscriptItemBlock(
                    item: SessionController.TranscriptItem(
                      kind: .answer, title: "Message \(index)",
                      text: String(repeating: "long message line\n", count: 20)),
                    theme: MacTheme()))
                  .focusTarget(messages[index])
                  .padding(EdgeInsets(top: 5, leading: 10, bottom: 5, trailing: 10))
                  .sizing(x: .grow))
              cachedRows[index] = row
              return row
            })
          Group("Composer") {
            TextField(text: { "" }, onChange: { _ in }).focusTarget(composer)
          }
        }
      }, prepare: { context = $0 }, finish: { context in
        if context.input.commands.contains(where: {
          if case .navigation = $0 { return true }
          return false
        }) { context.requestRedraw() }
      })
      .onCommand(.navigation(.sectionUp)) {
        if composer.isEditing { context?.endEditing() }
        return .ignored
      }
    }
    let ui = NavigationTestHost(content: content, size: Size(width: 600, height: 300), keyBindings: ScribeBlock.keyBindings)
    defer { ui.host.close() }
    #expect(controller.offset > 0)
    composer.focus(editing: true)
    ui.host.render()
    #expect(composer.isEditing)
    ui.press(KeyboardInput(chord: KeyChord("f", modifiers: .control)))
    #expect(!composer.isFocused)
    #expect(context?.navigationBreadcrumb == ["Window", "Conversation", "Transcript"])
    ui.press("l")
    #expect(context?.navigationSelectionIsGroup == false)
    #expect(messages.filter { $0.isFocused }.count == 1)
    let initialOffset = controller.offset
    ui.press("f", "f", "f", "f", "f")
    #expect(context?.navigationSelectionIsGroup == false)
    #expect(context?.navigationBreadcrumb == ["Window", "Conversation", "Transcript"])
    #expect(controller.offset < initialOffset)
    for _ in 0..<30 { ui.press("f") }
    #expect(messages[0].isFocused)
    #expect(controller.offset < initialOffset)
  }

  @Test func groupActionsAreIndependent() {
    var toggles = 0
    var creations = 0
    let renderer = HeadlessHost(size: Size(width: 400, height: 80))
    defer { renderer.close() }
    renderer.content = ScribeSessionGroup(
      id: "test-group", title: "Project", count: 3, isCollapsed: true,
      style: ScribeSessionGroupStyle(
        foreground: .white, hoveredForeground: .white, count: .white,
        newSession: .white, hoverBackground: .clear, fontScale: 1),
      onToggle: { toggles += 1 }, onNewSession: { creations += 1 })
    click("+", in: renderer)
    #expect(creations == 1)
    #expect(toggles == 0)
    click(">", in: renderer)
    #expect(toggles == 1)
    #expect(creations == 1)
  }

  @Test func rowUsesSuppliedDataStyleAndSelectionAction() {
    var selections = 0
    let color = Color(r: 0.7, g: 0.2, b: 0.4, a: 1)
    let renderer = HeadlessHost(size: Size(width: 400, height: 80))
    defer { renderer.close() }
    renderer.content = ScribeSessionRow(
      id: "test-session", title: "Planning", subtitle: "model", isSelected: true,
      style: ScribeSessionRowStyle(
        foreground: .white, secondaryForeground: .white, selectedForeground: color,
        activity: .white, selection: .clear, hover: .clear, border: color, fontScale: 1),
      onSelect: { selections += 1 })
    let frame = renderer.render()
    #expect(frame.commands.contains {
      if case .text(_, "Planning", let foreground, _) = $0 { return foreground == color }
      return false
    })
    click("Planning", in: renderer)
    #expect(selections == 1)
  }

  private func click(_ text: String, in renderer: HeadlessHost) {
    let frame = renderer.render()
    guard let position = frame.commands.compactMap({ command -> Point? in
      if case .text(let position, let value, _, _) = command, value == text { return position }
      return nil
    }).first else {
      Issue.record("Missing control: \(text)")
      return
    }
    let point = Point(x: position.x + 3, y: position.y + 3)
    renderer.render(input: InputState(pointerPosition: point, pointerPressed: true))
    renderer.render(input: InputState(pointerPosition: point, pointerReleased: true))
    renderer.render()
  }
}
