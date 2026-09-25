import Chroma

extension ScribeWorkspace {
  public var isStarting: Bool {
    if case .starting = store.phase { return true }
    return false
  }
  public var startupFailure: String? {
    if case .failed(let message) = store.phase { return message }
    return nil
  }
  public var showsSidebar: Bool { store.isSessionSidebarVisible }
  public var hasSession: Bool { store.active != nil }
  public var needsProject: Bool { store.requiresDirectoryBeforeStart && store.showDirectoryPicker }
  public var showsDirectoryPicker: Bool { store.showDirectoryPicker }
  public var error: String? { store.lastError }
  public var isOpeningSession: Bool { store.selectedSavedSession != nil }

  public func start() { store.start() }
  public func toggleSidebar() { store.toggleSessionSidebar() }
  public func newSession() { store.newSession() }
  public func resumeLatest() { store.resumeLatest() }
  public func dismissError() { store.dismissError() }

  public func sidebar(style: ScribeStyle) -> some Block {
    SessionSidebar(store: store, theme: style)
  }

  @BlockBuilder public func transcript(style: ScribeStyle) -> some Block {
    if let session = store.active {
      TranscriptView(session: session, theme: style)
    }
  }

  @BlockBuilder public func composer(style: ScribeStyle) -> some Block {
    if let session = store.active {
      BottomChrome(store: store, session: session, theme: style)
    }
  }

  public func directoryPicker(style: ScribeStyle) -> some Block {
    DirectoryPalette(store: store, theme: style, required: store.requiresDirectoryBeforeStart)
  }

  @BlockBuilder public func renameDialog(style: ScribeStyle) -> some Block {
    if let id = store.renamingSessionID {
      RenameSessionDialog(store: store, sessionID: id, theme: style)
    }
  }
}
