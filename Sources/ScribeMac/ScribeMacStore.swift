import Chroma
import Foundation
import Logging
import Observation
import ProfileRecorderServer
import ScribeCore
import ScribeKit
import SystemPackage

@MainActor
@Observable
final class ScribeMacStore {
  struct SavedSession: Identifiable, Sendable {
    let id: UUID
    let directory: FilePath
    let metadata: ChatSessionMetadata
    let lastMessageAt: Date
  }

  @MainActor
  enum SessionEntry {
    case open(SessionController)
    case saved(SavedSession)

    var id: UUID {
      switch self {
      case .open(let session): session.sessionId
      case .saved(let session): session.id
      }
    }

    var lastMessageAt: Date {
      switch self {
      case .open(let session): session.lastMessageAt
      case .saved(let session): session.lastMessageAt
      }
    }

    var isPinned: Bool {
      switch self {
      case .open(let session): session.isPinned
      case .saved(let session): session.metadata.isPinned
      }
    }
  }

  struct SessionGroup: Identifiable {
    let cwd: String
    let open: [SessionController]
    let entries: [SessionEntry]
    let totalSavedCount: Int

    var id: String { cwd }
    var totalSessionCount: Int { open.count + totalSavedCount }
    var visibleSavedCount: Int {
      entries.reduce(into: 0) { count, entry in
        if case .saved = entry { count += 1 }
      }
    }
    var hiddenSavedCount: Int { max(0, totalSavedCount - visibleSavedCount) }
    var canShowMore: Bool { hiddenSavedCount > 0 }
    var title: String {
      if cwd == "/" { return "/" }
      let name = (cwd as NSString).lastPathComponent
      return name.isEmpty ? cwd : name
    }
  }

  enum Phase {
    case starting
    case ready
    case failed(String)
  }

  static let shared = ScribeMacStore()
  static let composerFocus = FocusTarget()
  static let directoryPaletteFocus = FocusTarget()
  static let renameSessionFieldFocus = FocusTarget()
  static let composerID = "scribe-composer"

  var phase: Phase = .starting

  private(set) var sessions: [SessionController] = []
  private(set) var activeSessionID: UUID?
  private(set) var active: SessionController?
  private(set) var pendingSessionCount = 0
  private(set) var savedSessions: [SavedSession] = []
  private(set) var isLoadingSavedSessions = false
  private(set) var selectedSavedSession: SavedSession?
  private var openingSavedSessionIDs: Set<UUID> = []
  private var visibleSavedSessionCounts: [String: Int] = [:]
  private var expandedGroupCWDs: Set<String> = []
  private let savedSessionPageSize = 5
  let sidebarScroll = ScrollViewController()
  private(set) var isSessionSidebarVisible = true
  var lastError: String?

  var profileCatalog: [ProfileSummary] = []

  var showModelPicker = false

  private(set) var renamingSessionID: UUID?
  var renameSessionDraft = ""

  var showDirectoryPicker = false
  var directoryDraft = ""
  var directoryError = ""
  var directoryMatches: [String] = []
  var requiresDirectoryBeforeStart = false

  private var didStart = false
  private var profileRecorderTask: Task<Void, Never>?
  private var didSetupShellCapture = false
  private var composerFocusPending = false
  private var directoryFocusPending = false
  private var renameFocusPending = false
  private var directoryBaseCWD = FilePath.currentDirectory.string

  private init() {}

  func start() {
    guard !didStart else { return }
    didStart = true
    startProfileRecorder()
    let launchCWD = FilePath.currentDirectory.string
    directoryBaseCWD = launchCWD == "/" ? NSHomeDirectory() : launchCWD

    requiresDirectoryBeforeStart = false
    showDirectoryPicker = false
    phase = .ready
    refreshSavedSessions()
  }

  func toggleSessionSidebar() {
    isSessionSidebarVisible.toggle()
  }

  func closeSessionSidebar() {
    isSessionSidebarVisible = false
  }

  func newSession() {
    guard !isStarting else { return }
    guard let active else {
      requiresDirectoryBeforeStart = true
      openDirectoryPicker()
      return
    }
    newSession(in: active.workingDirectory)
  }

  func newSession(in workingDirectory: String) {
    guard !isStarting else { return }
    openSessionInBackground(workingDirectory: workingDirectory)
  }

  var sessionGroups: [SessionGroup] {
    let openIDs = Set(sessions.map(\.sessionId))
    var savedByCWD: [String: [SavedSession]] = [:]
    for saved in savedSessions where !openIDs.contains(saved.id) {
      savedByCWD[saved.metadata.cwd, default: []].append(saved)
    }
    var openByCWD: [String: [(offset: Int, element: SessionController)]] = [:]
    for entry in sessions.enumerated() {
      openByCWD[entry.element.workingDirectory, default: []].append(entry)
    }
    let cwdValues = Set(savedByCWD.keys).union(openByCWD.keys)
    return cwdValues.map { cwd in
      let allSaved = savedByCWD[cwd, default: []]
      let visibleCount = visibleSavedSessionCounts[cwd, default: savedSessionPageSize]
      let open = openByCWD[cwd, default: []].map(\.element)
      var entries = open.map(SessionEntry.open)
      entries.append(contentsOf: allSaved.prefix(visibleCount).map(SessionEntry.saved))
      entries.sort { lhs, rhs in
        if lhs.isPinned != rhs.isPinned { return lhs.isPinned }
        if lhs.lastMessageAt != rhs.lastMessageAt {
          return lhs.lastMessageAt > rhs.lastMessageAt
        }
        return lhs.id.uuidString > rhs.id.uuidString
      }
      return SessionGroup(
        cwd: cwd,
        open: open,
        entries: entries,
        totalSavedCount: allSaved.count)
    }.sorted { lhs, rhs in
      if lhs.totalSessionCount != rhs.totalSessionCount {
        return lhs.totalSessionCount > rhs.totalSessionCount
      }
      return lhs.cwd.localizedCaseInsensitiveCompare(rhs.cwd) == .orderedAscending
    }
  }

  func showMoreSavedSessions(for cwd: String) {
    visibleSavedSessionCounts[cwd, default: savedSessionPageSize] += savedSessionPageSize
  }

  func renameSession(_ id: UUID) {
    renameSessionDraft =
      sessions.first(where: { $0.sessionId == id })?.sessionName
      ?? savedSessions.first(where: { $0.id == id })?.metadata.name
      ?? ""
    renamingSessionID = id
    showDirectoryPicker = false
    showModelPicker = false
    renameFocusPending = true
  }

  func updateRenameSessionDraft(_ text: String) {
    renameSessionDraft = sanitizeASCII(text.replacingOccurrences(of: "\n", with: ""))
  }

  func submitSessionRename(_ proposed: String? = nil) {
    guard let id = renamingSessionID else { return }
    let name = sanitizeASCII(proposed ?? renameSessionDraft)
    cancelSessionRename(refocusComposer: false)
    updateSessionPresentation(id, name: name)
  }

  func cancelSessionRename(refocusComposer: Bool = true) {
    renamingSessionID = nil
    renameSessionDraft = ""
    renameFocusPending = false
    if refocusComposer { composerFocusPending = true }
  }

  func toggleSessionPin(_ id: UUID) {
    let pinned =
      sessions.first(where: { $0.sessionId == id })?.isPinned
      ?? savedSessions.first(where: { $0.id == id })?.metadata.isPinned
      ?? false
    updateSessionPresentation(id, isPinned: !pinned)
  }

  private func updateSessionPresentation(_ id: UUID, name: String? = nil, isPinned: Bool? = nil) {
    guard let directory = sessionDirectory(for: id) else { return }
    Task {
      do {
        let metadata = try await ChatSessionStore.updatePresentation(
          in: directory, name: name, isPinned: isPinned)
        sessions.first(where: { $0.sessionId == id })?.applyPresentation(
          name: metadata.name, isPinned: metadata.isPinned)
        refreshSavedSessions()
      } catch {
        reportError("Could not update session: \(error.localizedDescription)")
      }
    }
  }

  private func sessionDirectory(for id: UUID) -> FilePath? {
    if let session = sessions.first(where: { $0.sessionId == id }) {
      return session.boot.sessionDirectory
    }
    return savedSessions.first(where: { $0.id == id })?.directory
  }

  func isGroupCollapsed(_ cwd: String) -> Bool {
    if sessions.contains(where: { $0.workingDirectory == cwd && $0.isRunning }) {
      return false
    }
    return !expandedGroupCWDs.contains(cwd)
  }

  func toggleGroup(_ cwd: String) {
    if expandedGroupCWDs.contains(cwd) {
      expandedGroupCWDs.remove(cwd)
    } else {
      expandedGroupCWDs.insert(cwd)
    }
  }

  func refreshSavedSessions() {
    guard !isLoadingSavedSessions else { return }
    isLoadingSavedSessions = true
    Task {
      defer { isLoadingSavedSessions = false }
      do {
        let sessionsRoot = ScribePaths.resolve().sessionsDirectory
        savedSessions = try await Self.loadSavedSessions(sessionsRoot: sessionsRoot)
      } catch {
        reportError("Could not load saved sessions: \(error.localizedDescription)")
      }
    }
  }

  @concurrent
  private static func loadSavedSessions(sessionsRoot: FilePath) async throws -> [SavedSession] {
    let directories = try await ChatSessionStore.listSessionDirectories(sessionsRoot: sessionsRoot)
    return try directories.compactMap { directory in
      try Task.checkCancellation()
      guard let metadata = try? ChatSessionStore.loadMetadata(from: directory) else { return nil }
      return SavedSession(
        id: metadata.id,
        directory: directory,
        metadata: metadata,
        lastMessageAt: ChatSessionStore.lastMessageDate(in: directory, metadata: metadata))
    }
  }

  @concurrent
  private static func loadSavedSession(
    _ saved: SavedSession, version: String
  ) async throws -> BootstrappedSession {
    try Task.checkCancellation()
    return try await ScribeSessionBootstrap.open(
      resumeDirectory: saved.directory,
      workingDirectory: saved.metadata.cwd,
      version: version)
  }

  func openSavedSession(_ saved: SavedSession) {
    if let existing = sessions.first(where: { $0.sessionId == saved.id }) {
      switchTo(existing.sessionId)
      return
    }
    let previousID = activeSessionID
    selectedSavedSession = saved
    activeSessionID = nil
    active = nil
    for session in sessions { session.isActive = false }
    if let previousID { unloadIfIdle(previousID) }

    guard openingSavedSessionIDs.insert(saved.id).inserted else { return }
    pendingSessionCount += 1
    Task {
      defer {
        pendingSessionCount -= 1
        openingSavedSessionIDs.remove(saved.id)
      }
      do {
        try ensureShellCapture()
        let opened = try await Self.loadSavedSession(saved, version: GitVersion.hash)
        let shouldActivate = selectedSavedSession?.id == saved.id
        install(opened, refreshHistory: false, activate: shouldActivate)
      } catch {
        if selectedSavedSession?.id == saved.id { selectedSavedSession = nil }
        reportError("Could not open session \(saved.id.uuidString.prefix(8)): \(error.localizedDescription)")
      }
    }
  }

  func resumeLatest() {
    guard !isStarting else { return }
    let cwd = active?.workingDirectory ?? directoryBaseCWD
    pendingSessionCount += 1
    Task {
      defer { pendingSessionCount -= 1 }
      do {
        let directory = try await ChatSessionStore.resolveResumeDirectory(
          specifier: "latest",
          sessionsRoot: ScribePaths.resolve().sessionsDirectory,
          preferCWD: cwd)
        let metadata = try ChatSessionStore.loadMetadata(from: directory)
        if let existing = sessions.first(where: { $0.sessionId == metadata.id }) {
          switchTo(existing.sessionId)
          return
        }
        try ensureShellCapture()
        let opened = try await ScribeSessionBootstrap.open(
          resumeLatest: true,
          workingDirectory: cwd,
          version: GitVersion.hash)
        install(opened)
      } catch {
        reportError("Could not resume session: \(error.localizedDescription)")
      }
    }
  }

  func switchTo(_ id: UUID) {
    guard let target = sessions.first(where: { $0.sessionId == id }) else { return }
    let previousID = activeSessionID
    selectedSavedSession = nil
    activeSessionID = id
    active = target
    for session in sessions {
      let isActive = session.sessionId == id
      session.isActive = isActive
      if isActive { session.hasUnreadActivity = false }
    }
    if let previousID, previousID != id {
      unloadIfIdle(previousID)
    }
    composerFocusPending = true
  }

  private func unloadIfIdle(_ id: UUID) {
    guard id != activeSessionID,
      let index = sessions.firstIndex(where: { $0.sessionId == id && !$0.isRunning })
    else { return }
    let controller = sessions.remove(at: index)
    controller.shutdown(cancelTask: true)
  }

  func closeSession(_ id: UUID) {
    guard let index = sessions.firstIndex(where: { $0.sessionId == id }) else { return }
    let controller = sessions.remove(at: index)
    controller.shutdown(cancelTask: false)
    if activeSessionID == id {
      if sessions.isEmpty {
        activeSessionID = nil
        active = nil
      } else {
        let next = sessions[min(index, sessions.count - 1)]
        switchTo(next.sessionId)
      }
    }
    refreshSavedSessions()
  }

  private func install(
    _ opened: BootstrappedSession,
    refreshHistory: Bool = true,
    activate: Bool = true
  ) {
    let controller = SessionController(boot: opened)
    controller.onIdentityChange = { [weak self, weak controller] previous, successor in
      guard let self, let controller else { return }
      if self.activeSessionID == previous {
        self.activeSessionID = successor
        self.active = controller
      }
      self.refreshSavedSessions()
    }
    controller.onRunningChange = { [weak self, weak controller] running in
      guard let self, let controller, !running else { return }
      self.unloadIfIdle(controller.sessionId)
    }
    sessions.append(controller)
    profileCatalog = opened.profileCatalog
    requiresDirectoryBeforeStart = false
    lastError = nil
    phase = .ready
    if activate { switchTo(controller.sessionId) }
    if refreshHistory { refreshSavedSessions() }
  }

  private func openSessionInBackground(workingDirectory: String, reopenPaletteOnError: Bool = false) {
    pendingSessionCount += 1
    Task {
      defer { pendingSessionCount -= 1 }
      do {
        try ensureShellCapture()
        let opened = try await ScribeSessionBootstrap.open(
          workingDirectory: workingDirectory,
          version: GitVersion.hash)
        install(opened)
      } catch {
        if reopenPaletteOnError, sessions.isEmpty {
          requiresDirectoryBeforeStart = true
          showDirectoryPicker = true
          directoryDraft = workingDirectory
          directoryError = error.localizedDescription
          directoryFocusPending = true
        } else {
          reportError("Could not start session in \(workingDirectory): \(error.localizedDescription)")
        }
      }
    }
  }

  private func ensureShellCapture() throws {
    guard !didSetupShellCapture else { return }
    try ShellCaptureDirectory.setup(dataHome: ScribePaths.resolve().dataHomePath)
    didSetupShellCapture = true
  }

  private func reportError(_ message: String) {
    lastError = message
    if sessions.isEmpty, isStarting {
      phase = .ready
    }
  }

  private var isStarting: Bool {
    if case .starting = phase { return true }
    return false
  }

  func dismissError() {
    lastError = nil
  }

  func applyPendingFocus() {
    if renameFocusPending {
      Self.renameSessionFieldFocus.focus(editing: true)
      if ScribeRenderContext.current != nil {
        renameFocusPending = false
      }
      return
    }
    if directoryFocusPending {
      Self.directoryPaletteFocus.focus(editing: true)
      if ScribeRenderContext.current != nil {
        directoryFocusPending = false
      }
      return
    }
    if let active, active.wantsComposerFocus {
      active.wantsComposerFocus = false
      composerFocusPending = true
    }
    guard composerFocusPending else { return }
    Self.composerFocus.focus(editing: true)
    if ScribeRenderContext.current != nil {
      composerFocusPending = false
    }
  }

  func toggleDirectoryPicker() {
    if showDirectoryPicker && !requiresDirectoryBeforeStart {
      closeDirectoryPicker()
      return
    }
    openDirectoryPicker()
  }

  func openDirectoryPicker() {
    showModelPicker = false
    showDirectoryPicker = true
    directoryDraft = active?.workingDirectory ?? (directoryBaseCWD == "/" ? "~" : directoryBaseCWD)
    directoryError = ""
    directoryMatches = []
    directoryFocusPending = true
  }

  func finishDirectoryPaletteInput(_ context: RenderContext) {
    guard showDirectoryPicker, renamingSessionID == nil,
      context.input.textEvents.contains(.endEditing)
    else { return }
    if requiresDirectoryBeforeStart {
      Self.directoryPaletteFocus.focus(editing: true)
    } else {
      closeDirectoryPicker()
    }
    context.requestRedraw()
  }

  func closeDirectoryPicker() {
    guard !requiresDirectoryBeforeStart else { return }
    showDirectoryPicker = false
    directoryError = ""
    directoryMatches = []
    composerFocusPending = true
  }

  func updateDirectoryDraft(_ text: String) {
    directoryDraft = sanitizeASCII(text.replacingOccurrences(of: "\n", with: ""))
    directoryError = ""
    directoryMatches = []
  }

  func tabCompleteDirectory() {
    let result = DirectoryPathCompletion.tabComplete(
      input: directoryDraft,
      relativeTo: directoryResolutionBase)
    directoryDraft = sanitizeASCII(result.text)
    directoryMatches = result.matches
    directoryError = result.matches.isEmpty ? "No matching directories." : ""
    directoryFocusPending = true
  }

  func submitDirectory(_ proposed: String? = nil) {
    let text = sanitizeASCII((proposed ?? directoryDraft).trimmingCharacters(in: .whitespacesAndNewlines))
    guard !text.isEmpty else {
      directoryError = "path is empty"
      return
    }
    let result = DirectoryPathCompletion.resolve(
      input: text,
      relativeTo: directoryResolutionBase)
    guard let path = result.path else {
      directoryError = result.error ?? "Invalid directory."
      directoryMatches = []
      return
    }
    if !requiresDirectoryBeforeStart, path == active?.workingDirectory {
      closeDirectoryPicker()
      return
    }
    showDirectoryPicker = false
    directoryError = ""
    directoryMatches = []
    directoryFocusPending = false
    openSessionInBackground(workingDirectory: path, reopenPaletteOnError: true)
  }

  private var directoryResolutionBase: String {
    active?.workingDirectory ?? directoryBaseCWD
  }

  func toggleModelPicker() {
    guard active?.isRunning != true else { return }
    showDirectoryPicker = false
    showModelPicker.toggle()
  }

  func selectProfile(_ name: String) {
    showModelPicker = false
    guard let active, name != active.profileName else { return }
    Task {
      if let catalog = await active.applyModelProfile(name) {
        profileCatalog = catalog
      }
    }
  }

  private func startProfileRecorder() {
    profileRecorderTask = Task.detached {
      let logger = Logger(label: "scribe.mac.profile-recorder")
      do {
        #if DEBUG
        let environment = ProcessInfo.processInfo.environment
        if environment["PROFILE_RECORDER_SERVER_URL"] == nil
          && environment["PROFILE_RECORDER_SERVER_URL_PATTERN"] == nil
        {
          setenv(
            "PROFILE_RECORDER_SERVER_URL_PATTERN",
            "unix:///tmp/scribe-mac-{PID}.sock",
            0)
        }
        #endif
        let configuration = try await ProfileRecorderServerConfiguration.parseFromEnvironment()
        await ProfileRecorderServer(configuration: configuration).runIgnoringFailures(logger: logger)
      } catch {
        logger.warning("profile-recorder.configuration.failed", metadata: ["error": "\(error)"])
      }
    }
  }

  func close() {
    profileRecorderTask?.cancel()
    profileRecorderTask = nil
    for session in sessions {
      session.shutdown(cancelTask: true)
    }
    sessions = []
    activeSessionID = nil
    active = nil
    if didSetupShellCapture {
      ShellCaptureDirectory.teardown()
      didSetupShellCapture = false
    }
  }
}
