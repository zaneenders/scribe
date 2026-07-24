import Chroma
import Foundation
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
  /// Session opens currently bootstrapping (new / resume / directory change).
  private(set) var pendingSessionCount = 0
  /// Non-fatal failure shown as a dismissible banner over the session UI.
  var lastError: String?

  /// The session currently on screen, if any.
  var active: SessionController? {
    sessions.first { $0.sessionId == activeSessionID }
  }

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
  /// True when Finder-style launch at `/` must pick a directory before bootstrap.
  var requiresDirectoryBeforeStart = false

  private var didStart = false
  private var didSetupShellCapture = false
  private var composerFocusPending = false
  private var directoryFocusPending = false
  /// Cwd anchor for palette resolution before the first session exists.
  private var directoryBaseCWD = FilePath.currentDirectory.string

  private init() {}

  func start() {
    guard !didStart else { return }
    didStart = true
    #if canImport(AppKit)
    DirectoryPaletteKeyMonitor.shared.install()
    DirectoryPaletteKeyMonitor.shared.onTab = { [weak self] in
      self?.tabCompleteDirectory()
    }
    DirectoryPaletteKeyMonitor.shared.onEscape = { [weak self] in
      self?.closeDirectoryPicker()
    }
    #endif
    let launchCWD = FilePath.currentDirectory.string
    directoryBaseCWD = launchCWD
    if launchCWD == "/" {
      requiresDirectoryBeforeStart = true
      showDirectoryPicker = true
      directoryDraft = "~"
      directoryFocusPending = true
      phase = .starting
      return
    }
    Task {
      do {
        try ensureShellCapture()
        let opened = try await ScribeSessionBootstrap.open(
          workingDirectory: launchCWD,
          version: GitVersion.hash)
        install(opened)
      } catch {
        phase = .failed(error.localizedDescription)
      }
    }
  }

  // MARK: - Session lifecycle

  /// Opens a brand-new session in the background. Any turn already streaming
  /// in another session keeps running untouched.
  func newSession() {
    guard !isStarting else { return }
    openSessionInBackground(workingDirectory: active?.workingDirectory ?? directoryBaseCWD)
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
    guard sessions.contains(where: { $0.sessionId == id }) else { return }
    activeSessionID = id
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
      } else {
        let next = sessions[min(index, sessions.count - 1)]
        switchTo(next.sessionId)
      }
    }
  }

  private func install(_ opened: BootstrappedSession) {
    let controller = SessionController(boot: opened)
    sessions.append(controller)
    profileCatalog = opened.profileCatalog
    requiresDirectoryBeforeStart = false
    lastError = nil
    phase = .ready
    switchTo(controller.sessionId)
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
          requiresDirectoryBeforeStart = directoryBaseCWD == "/"
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
      Interaction.current.focus(Self.directoryPaletteID, editing: true)
      if Interaction.current.isTextEditing {
        directoryFocusPending = false
      }
      return
    }
    if let active, active.wantsComposerFocus {
      active.wantsComposerFocus = false
      composerFocusPending = true
    }
    guard composerFocusPending else { return }
    Interaction.current.focus(Self.composerID, editing: true)
    if Interaction.current.isTextEditing {
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

  func close() {
    #if canImport(AppKit)
    DirectoryPaletteKeyMonitor.shared.uninstall()
    #endif
    for session in sessions {
      session.shutdown(cancelTask: true)
    }
    sessions = []
    activeSessionID = nil
    if didSetupShellCapture {
      ShellCaptureDirectory.teardown()
      didSetupShellCapture = false
    }
  }
}
