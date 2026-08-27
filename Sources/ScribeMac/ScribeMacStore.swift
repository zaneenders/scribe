import Chroma
import Foundation
import Logging
import ProfileRecorderServer
import ScribeCore
import ScribeKit
import SystemPackage

/// Owns every open chat session and which one is on screen.
///
/// Sessions are independent ``SessionController``s: switching sessions or
/// starting a new one never interrupts a turn already streaming — the
/// controller keeps consuming events in the background and flags unread
/// activity for the sidebar.
@MainActor
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
  }

  struct SessionGroup: Identifiable {
    let cwd: String
    let open: [SessionController]
    /// Open and currently exposed saved sessions, newest message first.
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
  static let composerID = WidgetID("scribe-composer")
  static let directoryPaletteID = WidgetID("directory-palette")

  /// Startup phase. Only the initial bootstrap blanks the UI; later session
  /// opens run in the background and report through `pendingSessionCount`
  /// and `lastError`.
  var phase: Phase = .starting

  /// Live sessions, oldest first. Turns keep running while not active.
  private(set) var sessions: [SessionController] = []
  private(set) var activeSessionID: UUID?
  /// The session currently on screen, if any. Kept in sync with
  /// `activeSessionID` by `switchTo` / `closeSession` / `close` so view
  /// bodies don't rescan `sessions` every frame.
  private(set) var active: SessionController?
  /// Session opens currently bootstrapping (new / resume / directory change).
  private(set) var pendingSessionCount = 0
  /// Session metadata discovered on disk but not currently open.
  private(set) var savedSessions: [SavedSession] = []
  private(set) var isLoadingSavedSessions = false
  /// The saved session selected while its transcript and agent harness load.
  /// Keeping this separate from `active` lets the UI acknowledge selection on
  /// the very next frame instead of leaving the previous conversation visible.
  private(set) var selectedSavedSession: SavedSession?
  private var openingSavedSessionIDs: Set<UUID> = []
  private var visibleSavedSessionCounts: [String: Int] = [:]
  /// Session groups start collapsed and are added here only after the user opens them.
  private var expandedGroupCWDs: Set<String> = []
  private let savedSessionPageSize = 5
  let sidebarScroll = ScrollViewController()
  /// Whether the session browser is visible alongside the active conversation.
  private(set) var isSessionSidebarVisible = true
  /// Non-fatal failure shown as a dismissible banner over the session UI.
  var lastError: String?

  /// Profiles listed by the model picker; refreshed on every config load.
  var profileCatalog: [ProfileSummary] = []

  /// Whether the model picker overlay is visible.
  var showModelPicker = false

  /// Whether the directory palette is visible.
  var showDirectoryPicker = false
  /// Path typed into the palette's `$ cd` field.
  var directoryDraft = ""
  /// Validation or completion feedback for the palette.
  var directoryError = ""
  /// Directory names from the most recent Tab completion.
  var directoryMatches: [String] = []
  /// True until the user chooses the initial working directory.
  var requiresDirectoryBeforeStart = false

  private var didStart = false
  private var profileRecorderTask: Task<Void, Never>?
  private var didSetupShellCapture = false
  private var composerFocusPending = false
  private var directoryFocusPending = false
  /// Cwd anchor for palette resolution before the first session exists.
  private var directoryBaseCWD = FilePath.currentDirectory.string

  private init() {}

  func start() {
    guard !didStart else { return }
    didStart = true
    startProfileRecorder()
    #if canImport(AppKit)
    DirectoryPaletteKeyMonitor.shared.install()
    DirectoryPaletteKeyMonitor.shared.onTab = { [weak self] in
      self?.tabCompleteDirectory()
    }
    DirectoryPaletteKeyMonitor.shared.onEscape = { [weak self] in
      self?.closeDirectoryPicker()
    }
    DirectoryPaletteKeyMonitor.shared.onComposerSubmit = { [weak self] in
      self?.active?.submit()
    }
    DirectoryPaletteKeyMonitor.shared.onComposerStop = { [weak self] in
      guard let active = self?.active, active.isRunning else { return false }
      active.stop()
      return true
    }
    DirectoryPaletteKeyMonitor.shared.onComposerHistoryPrevious = { [weak self] in
      self?.active?.recallPreviousPrompt() ?? false
    }
    DirectoryPaletteKeyMonitor.shared.onComposerHistoryNext = { [weak self] in
      self?.active?.recallNextPrompt() ?? false
    }
    DirectoryPaletteKeyMonitor.shared.onCommandPickerMove = { [weak self] delta in
      self?.active?.moveCommandCursor(by: delta)
    }
    DirectoryPaletteKeyMonitor.shared.onCommandPickerToggle = { [weak self] in
      self?.active?.toggleCommandBoundary()
    }
    DirectoryPaletteKeyMonitor.shared.onCommandPickerConfirm = { [weak self] in
      self?.active?.confirmCommandPicker()
    }
    DirectoryPaletteKeyMonitor.shared.onCommandPickerCancel = { [weak self] in
      self?.active?.cancelCommandPicker()
    }
    DirectoryPaletteKeyMonitor.shared.copyText = {
      SelectionManager.shared.selectedText()
    }
    #endif
    let launchCWD = FilePath.currentDirectory.string
    // Finder launches at `/`, which is not a useful default for a new session.
    // Use the home directory until the user picks a directory from Directory.
    directoryBaseCWD = launchCWD == "/" ? NSHomeDirectory() : launchCWD

    // The session sidebar is now the launch screen: users can open history,
    // start in the launch directory, or choose another directory from there.
    requiresDirectoryBeforeStart = false
    showDirectoryPicker = false
    phase = .ready
    refreshSavedSessions()
  }

  // MARK: - Session lifecycle

  func toggleSessionSidebar() {
    isSessionSidebarVisible.toggle()
  }

  func closeSessionSidebar() {
    isSessionSidebarVisible = false
  }

  /// Opens a brand-new session in the background. Any turn already streaming
  /// in another session keeps running untouched.
  func newSession() {
    guard !isStarting else { return }
    // The launch screen should not silently create a session in Finder's or the
    // process's working directory. Make the project choice explicit; once a
    // session is open, New keeps the convenient same-project behavior.
    guard let active else {
      requiresDirectoryBeforeStart = true
      openDirectoryPicker()
      return
    }
    newSession(in: active.workingDirectory)
  }

  /// Opens a brand-new chat in a specific session-sidebar directory.
  func newSession(in workingDirectory: String) {
    guard !isStarting else { return }
    openSessionInBackground(workingDirectory: workingDirectory)
  }

  var sessionGroups: [SessionGroup] {
    // Build the grouping tables once. Filtering the entire saved-session list
    // once per directory made every sidebar frame quadratic as history grew.
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

  // Open sessions are ordered solely by conversation recency above; UI state
  // such as running, unread, or selected must not reorder them.

  func showMoreSavedSessions(for cwd: String) {
    visibleSavedSessionCounts[cwd, default: savedSessionPageSize] += savedSessionPageSize
  }

  func isGroupCollapsed(_ cwd: String) -> Bool {
    // Running sessions stay visible even if their directory was collapsed.
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
        // Directory enumeration, stat, and metadata decoding are synchronous.
        // Keep all of them off the main actor so launch can draw immediately.
        savedSessions = try await Task.detached {
          let directories = try await ChatSessionStore.listSessionDirectories(
            sessionsRoot: sessionsRoot)
          return directories.compactMap { directory in
            guard let metadata = try? ChatSessionStore.loadMetadata(from: directory) else { return nil }
            return SavedSession(
              id: metadata.id,
              directory: directory,
              metadata: metadata,
              lastMessageAt: ChatSessionStore.lastMessageDate(
                in: directory, metadata: metadata))
          }
        }.value
      } catch {
        reportError("Could not load saved sessions: \(error.localizedDescription)")
      }
    }
  }

  func openSavedSession(_ saved: SavedSession) {
    if let existing = sessions.first(where: { $0.sessionId == saved.id }) {
      switchTo(existing.sessionId)
      return
    }
    // Update selection synchronously so the click never appears to be ignored.
    selectedSavedSession = saved
    activeSessionID = nil
    active = nil
    for session in sessions { session.isActive = false }

    guard openingSavedSessionIDs.insert(saved.id).inserted else { return }
    pendingSessionCount += 1
    Task {
      defer {
        pendingSessionCount -= 1
        openingSavedSessionIDs.remove(saved.id)
      }
      do {
        try ensureShellCapture()
        // Bootstrap performs synchronous file decoding internally. Run it on a
        // detached executor so multi-megabyte transcripts do not block drawing.
        let version = GitVersion.hash
        let opened = try await Task.detached {
          try await ScribeSessionBootstrap.open(
            resumeDirectory: saved.directory,
            workingDirectory: saved.metadata.cwd,
            version: version)
        }.value
        let shouldActivate = selectedSavedSession?.id == saved.id
        install(opened, refreshHistory: false, activate: shouldActivate)
      } catch {
        if selectedSavedSession?.id == saved.id { selectedSavedSession = nil }
        reportError("Could not open session \(saved.id.uuidString.prefix(8)): \(error.localizedDescription)")
      }
    }
  }

  /// Resumes the most recently saved session, or switches to it when it is
  /// already open here — two live controllers on one session file would
  /// interleave writes to its transcript.
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

  /// Brings a session on screen. Its turn — running or not — is unaffected;
  /// the previously visible session keeps streaming in the background.
  func switchTo(_ id: UUID) {
    guard let target = sessions.first(where: { $0.sessionId == id }) else { return }
    selectedSavedSession = nil
    activeSessionID = id
    active = target
    for session in sessions {
      let isActive = session.sessionId == id
      session.isActive = isActive
      if isActive { session.hasUnreadActivity = false }
    }
    composerFocusPending = true
  }

  /// Removes a session. An in-flight turn is interrupted but its streaming
  /// task is left to wind down so the interrupted turn persists cleanly.
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
    sessions.append(controller)
    profileCatalog = opened.profileCatalog
    requiresDirectoryBeforeStart = false
    lastError = nil
    phase = .ready
    if activate { switchTo(controller.sessionId) }
    // Opening an existing item does not change the set of sessions on disk.
    // Avoid rereading metadata for every saved session after each selection.
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
    // With no sessions to fall back on, still leave the empty state usable
    // rather than the fatal startup screen.
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

  /// Focus must be requested after a frame has registered the target leaf.
  func applyPendingFocus() {
    if directoryFocusPending {
      MacRenderContext.current?.focus(Self.directoryPaletteID, editing: true)
      if MacRenderContext.current != nil {
        directoryFocusPending = false
      }
      return
    }
    if let active, active.wantsComposerFocus {
      active.wantsComposerFocus = false
      composerFocusPending = true
    }
    guard composerFocusPending else { return }
    MacRenderContext.current?.focus(Self.composerID, editing: true)
    if MacRenderContext.current != nil {
      composerFocusPending = false
    }
  }

  // MARK: - Directory palette

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
    // Starts a new session in the chosen directory; the current session, if
    // any, keeps running in the background.
    openSessionInBackground(workingDirectory: path, reopenPaletteOnError: true)
  }

  private var directoryResolutionBase: String {
    active?.workingDirectory ?? directoryBaseCWD
  }

  // MARK: - Model picker

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

  // MARK: - App teardown

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
    #if canImport(AppKit)
    DirectoryPaletteKeyMonitor.shared.uninstall()
    #endif
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
