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
  /// Tab is forwarded to the shell for command and path completion.
  static let complete = Command.application("scribe.terminal.complete")
  /// Arrow keys encoded from the active Ghostty terminal modes so shells get history recall.
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

  private static let client = InProcessTerminalClient()

  private let model: GhosttyTerminal?
  private let workingDirectory: String
  private var columns: UInt16 = 80
  private var rows: UInt16 = 24
  private var terminalID: TerminalID?
  private var attachment: TerminalAttachment?
  private var eventTask: Task<Void, Never>?
  private var shellGeneration = UUID()
  private(set) var startupError: String?

  init(sessionId: UUID, workingDirectory: String) {
    inputID = WidgetID("terminal.input.\(sessionId.uuidString)")
    self.workingDirectory = workingDirectory
    do {
      let model = try GhosttyTerminal()
      self.model = model
      startShell(in: model)
    } catch {
      self.model = nil
      self.startupError = String(describing: error)
    }
  }

  /// Starts a shell and connects it to the existing terminal grid. Keeping the
  /// grid lets scrollback survive an `exit`, while replacing the PTY makes the
  /// terminal immediately usable again.
  private func startShell(in model: GhosttyTerminal) {
    let generation = UUID()
    shellGeneration = generation
    eventTask?.cancel()
    eventTask = Task { [weak self, weak model] in
      guard let self, let model else { return }
      do {
        let id = try await Self.client.createTerminal(
          configuration: TerminalConfiguration(
            workingDirectory: workingDirectory,
            size: TerminalSize(columns: columns, rows: rows)))
        guard !Task.isCancelled, shellGeneration == generation else {
          await Self.client.close(id)
          return
        }
        terminalID = id
        startupError = nil

        // Rendering can briefly fall behind bursty programs such as Neovim. The
        // runtime intentionally disconnects a full bounded attachment rather than
        // allowing it to grow forever. Resume from the last byte rendered; replay
        // fills the gap without restarting the shell or losing terminal output.
        var cursor: UInt64?
        while !Task.isCancelled, shellGeneration == generation {
          let attachment = try await Self.client.attach(to: id, after: cursor)
          self.attachment = attachment
          do {
            for try await event in attachment.events {
              guard !Task.isCancelled, shellGeneration == generation else { return }
              switch event {
              case .output(let output):
                model.write(output.data)
                cursor = output.endCursor
              case .exit(let status):
                model.write("\r\n\u{1B}[33m[shell exited: \(status); starting a new shell]\u{1B}[0m\r\n")
                terminalID = nil
                self.attachment = nil
                startShell(in: model)
                return
              }
            }
            return
          } catch TerminalRuntimeError.slowConsumer {
            self.attachment = nil
            continue
          }
        }
      } catch is CancellationError {
        return
      } catch {
        guard shellGeneration == generation else { return }
        startupError = String(describing: error)
        model.write("\r\n\u{1B}[31m[could not start shell: \(error)]\u{1B}[0m\r\n")
      }
    }

    model.onInput = { [weak self] input in
      guard let self, let id = self.terminalID else { return }
      Task { try? await Self.client.write(input, to: id) }
    }
    model.onResize = { [weak self] columns, rows in
      guard let self else { return }
      self.columns = columns
      self.rows = rows
      guard let id = self.terminalID else { return }
      Task { try? await Self.client.resize(id, to: TerminalSize(columns: columns, rows: rows)) }
    }
  }

  func noteEditing(_ editing: Bool) {
    guard editing != isEditing else { return }
    isEditing = editing
    if editing {
      wantsFocus = false
      ScribeRenderContext.activeTextInput = inputID
    } else if ScribeRenderContext.activeTextInput == inputID {
      ScribeRenderContext.activeTextInput = nil
    }
  }

  func interrupt() {
    guard let id = terminalID else { return }
    Task { try? await Self.client.interrupt(id) }
  }

  func send(_ text: String) {
    guard let id = terminalID else { return }
    Task { try? await Self.client.write(text, to: id) }
  }

  func send(key: GhosttyTerminalKey) {
    guard let input = model?.encodeKey(key), let id = terminalID else { return }
    Task { try? await Self.client.write(input, to: id) }
  }

  /// Hangs up the shell; called when the owning session closes.
  func close() {
    shellGeneration = UUID()
    eventTask?.cancel()
    eventTask = nil
    let attachment = self.attachment
    self.attachment = nil
    let id = terminalID
    terminalID = nil
    Task {
      await attachment?.detach()
      if let id { await Self.client.close(id) }
    }
  }

  func makeView(theme: MacTheme) -> GhosttyTerminalView? {
    model?.view(
      id: inputID,
      fontScale: theme.terminalScale,
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
      .onCommand(ScribeTerminalCommand.complete) {
        guard terminal.isEditing else { return .ignored }
        terminal.send(key: .tab)
        return .handled
      }
      .onCommand(ScribeTerminalCommand.lineUp) {
        guard terminal.isEditing else { return .ignored }
        terminal.send(key: .arrowUp)
        return .handled
      }
      .onCommand(ScribeTerminalCommand.lineDown) {
        guard terminal.isEditing else { return .ignored }
        terminal.send(key: .arrowDown)
        return .handled
      }
    BlockEngine.draw(content, into: &drawList, in: rect, context: context)
  }
}
