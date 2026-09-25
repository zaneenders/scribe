import Chroma
import HeadlessBackend
import Testing

@testable import ScribeBlocks

@MainActor
struct WorkspaceComponentsTests {
  @Test func transcriptPanelAcceptsIndependentHeaderContentAndStyle() {
    let background = Color(r: 0.2, g: 0.3, b: 0.4, a: 1)
    let renderer = HeadlessRenderer(size: Size(width: 400, height: 200))
    defer { renderer.close() }
    renderer.content = ScribeTranscriptPanel(
      style: ScribeTranscriptPanelStyle(background: background, border: .clear, cornerRadius: 7),
      header: Text("Tool output"), content: Text("Result"))
    let frame = renderer.render()
    let texts = frame.commands.compactMap { command -> String? in
      if case .text(_, let text, _, _) = command { return text }
      return nil
    }
    #expect(texts.contains("Tool output"))
    #expect(texts.contains("Result"))
    #expect(frame.commands.contains {
      if case .fillRoundedRect(_, _, let color) = $0 { return color == background }
      return false
    })
  }

  @Test func workspaceExposesStartupAndSidebarStateWithoutRootLayout() {
    let workspace = ScribeWorkspace()
    workspace.store.phase = .starting
    #expect(workspace.isStarting)
    #expect(workspace.startupFailure == nil)
    workspace.store.phase = .failed("Unavailable")
    #expect(!workspace.isStarting)
    #expect(workspace.startupFailure == "Unavailable")
    let visible = workspace.showsSidebar
    workspace.toggleSidebar()
    #expect(workspace.showsSidebar != visible)
    #expect(!workspace.hasSession)
  }

  @Test func workspaceScopeDoesNotAddApplicationChrome() {
    let renderer = HeadlessRenderer(size: Size(width: 400, height: 200))
    defer { renderer.close() }
    renderer.content = ScribeWorkspaceScope(content: Text("Host layout"), workspace: ScribeWorkspace())
    let texts = renderer.render().commands.compactMap { command -> String? in
      if case .text(_, let text, _, _) = command { return text }
      return nil
    }
    #expect(texts == ["Host layout"])
  }
}
