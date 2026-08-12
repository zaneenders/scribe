import Chroma
import Foundation
import ScribeTerminal

/// Application commands routed to the focused terminal tab. Bound globally in
/// ``ScribeBlock/keyBindings``; they only take effect inside the terminal's
/// focus scope (see `FocusInteraction.routePendingCommands`).
enum ScribeTerminalCommand {
  /// Ctrl-C: delivered to the PTY's foreground process group as SIGINT.
  static let interrupt = Command.application("scribe.terminal.interrupt")
  /// Ctrl-/ is encoded by legacy terminals as US (0x1F), the same byte as
  /// Ctrl-_. Neovim plugins commonly bind this chord to toggle a terminal.
  static let controlSlash = Command.application("scribe.terminal.controlSlash")
  /// Arrow keys forwarded as ANSI cursor keys so shells get history recall.
  static let lineUp = Command.application("scribe.terminal.lineUp")
  static let lineDown = Command.application("scribe.terminal.lineDown")
}

/// A session's terminal: a `GhosttyTerminal` model fed by a login shell on a
/// PTY rooted at the session's working directory.
///
/// Created lazily the first time the user opens the Terminal tab and lives as
/// long as its `SessionController`, so the shell keeps running while the user
/// is on the Chat tab or another session.
@MainActor
final class SessionTerminal {
  /// Focus identity of the terminal pane; unique per session.
  let inputID: WidgetID
  /// Set when the tab is (re)opened; the tab content retries focusing until
  /// the pane's leaf exists in the focus tree and editing begins.
  var wantsFocus = false
  /// Mirrored from the view's editing state so command handlers can gate
  /// input that only makes sense while the pane is live.
  private(set) var isEditing = false

  private let model: GhosttyTerminal?
  private var pty: PTYSession?
  private(set) var startupError: String?

  init(sessionId: UUID, workingDirectory: String) {
    inputID = WidgetID("terminal.input.\(sessionId.uuidString)")
    do {
      let model = try GhosttyTerminal()
      let pty = try PTYSession(workingDirectory: workingDirectory)
      pty.onOutput = { [weak model] data in model?.write(data) }
      pty.onExit = { [weak model] status in
        model?.write("\r\n\u{1B}[31m[shell exited: \(status)]\u{1B}[0m\r\n")
      }
      model.onInput = { [weak pty] input in pty?.write(input) }
      model.onResize = { [weak pty] columns, rows in
        pty?.resize(columns: columns, rows: rows)
      }
      self.model = model
      self.pty = pty
    } catch {
      self.model = nil
      self.pty = nil
      self.startupError = String(describing: error)
    }
  }

  func noteEditing(_ editing: Bool) {
    guard editing != isEditing else { return }
    isEditing = editing
    if editing {
      wantsFocus = false
      MacRenderContext.activeTextInput = inputID
    } else if MacRenderContext.activeTextInput == inputID {
      MacRenderContext.activeTextInput = nil
    }
  }

  func interrupt() { pty?.interrupt() }
  func send(_ text: String) { pty?.write(text) }

  /// Hangs up the shell; called when the owning session closes.
  func close() {
    pty?.close()
    pty = nil
  }

  func makeView(theme: MacTheme) -> GhosttyTerminalView? {
    model?.view(
      id: inputID,
      fontScale: theme.textScale,
      colors: GhosttyTerminalColors(
        background: theme.codeBackground,
        foreground: theme.textPrimary,
        cursor: theme.accent,
        focusedBorder: theme.accent),
      onEditingChanged: { [weak self] editing in
        self?.noteEditing(editing)
      })
  }
}

/// The Terminal tab's content: the live terminal pane, or the startup error
/// when the shell could not be launched.
struct TerminalTabContent: PrimitiveBlock {
  let terminal: SessionTerminal
  let theme: MacTheme

  @MainActor var expandsHorizontally: Bool { true }
  @MainActor var expandsVertically: Bool { true }

  @MainActor func sizeThatFits(_ proposal: Size, context: RenderContext) -> Size { proposal }

  @MainActor func draw(into drawList: inout DrawList, in rect: Rect, context: RenderContext) {
    guard let view = terminal.makeView(theme: theme) else {
      let message = VStack(spacing: 8) {
        Spacer()
        Text("Could not start the terminal")
          .fontScale(theme.textScale)
          .foregroundColor(theme.errorText)
        WrappedText(
          text: terminal.startupError ?? "unknown error",
          theme: theme, color: theme.textSecondary)
        Spacer()
      }
      .padding(theme.margin)
      BlockEngine.draw(message, into: &drawList, in: rect, context: context)
      return
    }

    // Focus retries live here because the pane's leaf only exists in the focus
    // tree after the tab's first frame; `focus` no-ops until it does.
    if terminal.wantsFocus {
      context.focus(terminal.inputID, editing: true)
    }

    let content = view
      .onCommand(ScribeTerminalCommand.interrupt) {
        terminal.interrupt()
        return .handled
      }
      .onCommand(ScribeTerminalCommand.controlSlash) {
        guard terminal.isEditing else { return .ignored }
        terminal.send("\u{1F}")
        return .handled
      }
      .onCommand(ScribeTerminalCommand.lineUp) {
        guard terminal.isEditing else { return .ignored }
        terminal.send("\u{1B}[A")
        return .handled
      }
      .onCommand(ScribeTerminalCommand.lineDown) {
        guard terminal.isEditing else { return .ignored }
        terminal.send("\u{1B}[B")
        return .handled
      }
    BlockEngine.draw(content, into: &drawList, in: rect, context: context)
  }
}

/// The Chat | Terminal switcher above a ready session's content.
struct SessionTabStrip: Block {
  let session: SessionController
  let theme: MacTheme

  @MainActor var body: some Block {
    HStack(spacing: 0) {
      tabButton(.chat)
      tabButton(.terminal)
      Spacer()
      if session.selectedTab == .terminal {
        Text("type into the pane · Esc passes through · Ctrl-C interrupts")
          .fontScale(theme.smallScale)
          .foregroundColor(theme.textSecondary)
          .padding(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: theme.margin))
      }
    }
    .sizing(y: .fixed(28))
    .sizing(x: .grow)
    .background(theme.headerBackground)
    .border(theme.border)
  }

  @MainActor private func tabButton(_ tab: SessionController.ContentTab) -> some Block {
    let active = session.selectedTab == tab
    return Interactive(
      id: WidgetID("session-tab-\(tab.rawValue).\(session.sessionId.uuidString)"),
      action: { session.selectTab(tab) }
    ) { phase in
      Text(tab.rawValue)
        .fontScale(theme.smallScale)
        .foregroundColor(
          active ? theme.accent : phase == .hovered ? theme.textPrimary : theme.textSecondary
        )
        .padding(EdgeInsets(top: 6, leading: 14, bottom: 6, trailing: 14))
        .background(
          active ? theme.panelBackground : phase == .hovered ? theme.sidebarHover : .clear
        )
        .border(active ? theme.accent : .clear, width: active ? 1 : 0)
    }
  }
}
