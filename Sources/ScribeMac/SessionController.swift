import Chroma
import Foundation
import ScribeCore
import ScribeKit

/// One open chat session: its harness, transcript, composer draft, and any
/// turn currently streaming.
///
/// Controllers live independently of which session is on screen, so a turn
/// keeps running in the background while the user switches to another session
/// or starts a new one. Activity arriving while off-screen raises
/// `hasUnreadActivity` for the sidebar.
@MainActor
final class SessionController {

  enum ItemKind {
    case user
    case answer
    case reasoning
    case tool
    case notice
    case warning
    case error
  }

  struct TranscriptItem: Identifiable {
    let id = UUID()
    var kind: ItemKind
    var title: String
    var text: String
    var running = false
    var layoutRevision = 0

    var layoutID: WidgetID {
      WidgetID("transcript-row:\(id.uuidString):\(layoutRevision)")
    }
  }

  private enum StreamEvent: Sendable {
    case userPrompt(String)
    case agent(AgentEvent)
    case finished(TurnOutcome)
    case failed(String)
  }

  /// The bootstrapped session this controller drives.
  let boot: BootstrappedSession

  var transcript: [TranscriptItem]
  /// Composer text, already sanitized to ASCII by the TextField's `onChange`.
  /// This is the single sanitization boundary: `submit` reads the draft (via
  /// the no-argument call path) rather than the field's raw buffer, so
  /// non-ASCII text can't reach the harness. `proposed` arguments are only
  /// passed text that already crossed that boundary (e.g. queued messages).
  var draft = ""
  var isRunning = false
  var usageText = ""
  /// Set by the store. While false, incoming stream activity raises
  /// `hasUnreadActivity` so the sidebar can flag background progress.
  var isActive = false
  var hasUnreadActivity = false
  /// Set when a turn finishes while on screen; the store consumes it to
  /// refocus the composer.
  var wantsComposerFocus = false
  let scroll = ScrollViewController()

  var profileName: String
  var modelName: String

  private var runTask: Task<Void, Never>?
  private var promptHistory: [String]
  private var historyIndex: Int?
  private var draftBeforeHistory = ""
  /// Non-nil when the user requested a force-send of a queued message while
  /// the model was busy.  Consumed in `handle(_:)` after the current turn
  /// finishes (including after an interrupt), so the queued message is not
  /// lost.
  private var pendingForceSend: String?

  var sessionId: UUID { boot.sessionId }
  var workingDirectory: String { boot.workingDirectory }
  /// Messages queued while a turn is running, oldest first.
  var queuedTexts: [String] { boot.messageQueues.steeringPreviewTexts() }
  var sessionIdText: String { sessionId.uuidString.prefix(8).uppercased() }
  /// Short label for the session list: the working directory's basename.
  var directoryTitle: String {
    if workingDirectory == "/" { return "/" }
    let last = (workingDirectory as NSString).lastPathComponent
    return last.isEmpty ? workingDirectory : last
  }

  init(boot: BootstrappedSession) {
    self.boot = boot
    self.profileName = boot.profile.name
    self.modelName = boot.profile.model
    self.transcript = Self.replay(boot.initialMessages)
    self.promptHistory = boot.initialMessages.compactMap { message in
      message.role == .user && !message.content.isEmpty ? message.content : nil
    }
  }

  // MARK: - Composer editing

  func updateDraft(_ text: String) {
    draft = sanitizeASCII(text)
    historyIndex = nil
    draftBeforeHistory = ""
  }

  func insertComposerNewline() {
    draft.append("\n")
    historyIndex = nil
    draftBeforeHistory = ""
    Interaction.current.focus(ScribeMacStore.composerID, editing: true)
  }

  /// Recalls submitted prompts only when the composer is empty or already in
  /// history-navigation mode, leaving arrow keys available for caret movement
  /// while the user is editing a draft.
  @discardableResult
  func recallPreviousPrompt() -> Bool {
    guard !promptHistory.isEmpty, draft.isEmpty || historyIndex != nil else { return false }
    if historyIndex == nil {
      draftBeforeHistory = draft
      historyIndex = promptHistory.count - 1
    } else if let index = historyIndex, index > 0 {
      historyIndex = index - 1
    }
    if let historyIndex { draft = promptHistory[historyIndex] }
    Interaction.current.focus(ScribeMacStore.composerID, editing: true)
    return true
  }

  @discardableResult
  func recallNextPrompt() -> Bool {
    guard let index = historyIndex else { return false }
    if index + 1 < promptHistory.count {
      historyIndex = index + 1
      draft = promptHistory[index + 1]
    } else {
      historyIndex = nil
      draft = draftBeforeHistory
      draftBeforeHistory = ""
    }
    Interaction.current.focus(ScribeMacStore.composerID, editing: true)
    return true
  }

  // MARK: - Sending

  func submit(_ proposed: String? = nil) {
    let text = (proposed ?? draft).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return }
    if isRunning {
      enqueue(text)
      return
    }
    startTurn(text: text)
  }

  /// Starts a turn for `text`, wiring the harness's event callbacks into a
  /// stream consumed on the main actor. Shared by `submit` and
  /// `forceSendNext`.
  private func startTurn(text: String) {
    rememberPrompt(text)
    draft = ""
    historyIndex = nil
    draftBeforeHistory = ""
    isRunning = true

    let harness = boot.harness
    let (events, continuation) = AsyncStream<StreamEvent>.makeStream()
    runTask = Task { [weak self] in
      guard let self else { return }
      let consumer = Task { @MainActor [weak self] in
        for await event in events {
          self?.handle(event)
        }
      }
      do {
        let outcome = try await harness.submit(
          text,
          onUserPrompt: { prompt in continuation.yield(.userPrompt(prompt)) },
          onEvent: { event in continuation.yield(.agent(event)) })
        continuation.yield(.finished(outcome))
      } catch {
        continuation.yield(.failed(error.localizedDescription))
      }
      continuation.finish()
      _ = await consumer.result
    }
  }

  /// Queue a message while the model is busy. The harness drains the steering
  /// queue after the current turn, matching the CLI's Enter-while-busy path.
  private func enqueue(_ text: String) {
    guard boot.messageQueues.enqueueSteering(text: text) else { return }
    rememberPrompt(text)
    draft = ""
    historyIndex = nil
    draftBeforeHistory = ""
  }

  private func rememberPrompt(_ text: String) {
    if promptHistory.last != text {
      promptHistory.append(text)
    }
  }

  func stop() {
    guard isRunning else { return }
    // Interrupt the current turn while preserving queued messages so the
    // user can still force-send them afterward (matching the CLI behaviour
    // where Ctrl+C / Enter-on-empty during a turn keeps the queue intact).
    let queuedCount = boot.messageQueues.steeringCount()
    if queuedCount > 0 {
      transcript.append(
        TranscriptItem(
          kind: .notice, title: "Queue",
          text: "Turn interrupted. \(queuedCount) queued message\(queuedCount == 1 ? "" : "s") preserved."))
    }
    Task { await boot.harness.interrupt() }
  }

  func clearQueue() {
    let dropped = discardQueuedMessages()
    guard dropped > 0 else { return }
    transcript.append(
      TranscriptItem(
        kind: .notice, title: "Queue",
        text: "Cleared \(dropped) queued message\(dropped == 1 ? "" : "s")."))
    scroll.scrollToBottom()
  }

  /// Pops the next queued steering message and sends it immediately.
  ///
  /// When the model is busy the current turn is interrupted first; the
  /// popped message is held in `pendingForceSend` and dispatched as soon as
  /// the turn finishes.  When idle the message is sent directly.
  func forceSendNext() {
    guard let text = boot.messageQueues.popSteeringForRecall() else { return }
    transcript.append(
      TranscriptItem(
        kind: .notice, title: "Queue",
        text: "Force-sending next: \(queuePreview(text))"))
    if isRunning {
      pendingForceSend = text
      Task { await boot.harness.interrupt() }
      return
    }
    startTurn(text: text)
  }

  private func queuePreview(_ text: String, limit: Int = 80) -> String {
    let flat = sanitizeASCII(text.replacingOccurrences(of: "\n", with: " "))
    guard flat.count > limit else { return flat }
    return String(flat.prefix(limit - 3)) + "..."
  }

  @discardableResult
  private func discardQueuedMessages() -> Int {
    let queues = boot.messageQueues
    let count = queues.steeringCount() + queues.followUpCount()
    queues.clearAll()
    return count
  }

  /// Interrupts any in-flight turn and drops queued messages. When
  /// `cancelTask` is false the streaming task is left to wind down so the
  /// interrupted turn is persisted cleanly before the controller is released;
  /// app teardown passes true to cancel immediately.
  func shutdown(cancelTask: Bool) {
    boot.messageQueues.clearAll()
    Task { await boot.harness.interrupt() }
    if cancelTask {
      runTask?.cancel()
    }
    runTask = nil
  }

  // MARK: - Model switching

  /// Applies a profile to this session's harness. Returns the fresh profile
  /// catalog on success so the store can update the shared picker list.
  @discardableResult
  func applyModelProfile(_ name: String) async -> [ProfileSummary]? {
    let previousName = profileName
    do {
      let loaded = try await ConfigLoader.load(profileOverride: name)
      let newConfig = ScribeConfig(
        agentModel: loaded.scribeConfig.agentModel,
        contextWindow: loaded.scribeConfig.contextWindow,
        contextWindowThreshold: loaded.scribeConfig.contextWindowThreshold,
        serverURL: loaded.scribeConfig.serverURL,
        apiKey: loaded.scribeConfig.apiKey,
        apiType: loaded.apiType,
        tools: ScribeSystemPrompt.defaultTools(),
        workingDirectory: workingDirectory,
        reasoningEnabled: loaded.scribeConfig.reasoningEnabled,
        reasoningEffort: loaded.scribeConfig.reasoningEffort,
        maxTokens: loaded.scribeConfig.maxTokens
      )
      try await boot.harness.reconfigure(configuration: newConfig)
      profileName = loaded.activeProfileName
      modelName = loaded.scribeConfig.agentModel
      let message: String
      if name == previousName {
        message = "Model reloaded: \(name) (\(modelName))"
      } else {
        message = "Switched to \(name) (\(modelName))"
      }
      transcript.append(TranscriptItem(kind: .notice, title: "Model", text: message))
      scroll.scrollToBottom()
      return loaded.profiles
    } catch {
      transcript.append(
        TranscriptItem(
          kind: .error, title: "Error",
          text: "Could not switch model: \(error.localizedDescription)"))
      return nil
    }
  }

  // MARK: - Stream handling

  private func handle(_ event: StreamEvent) {
    if !isActive {
      hasUnreadActivity = true
    }
    switch event {
    case .userPrompt(let text):
      // Echoes both the submitted message and queued messages as the harness
      // dispatches them at the start of each turn.
      transcript.append(TranscriptItem(kind: .user, title: "You", text: text))
      scroll.scrollToBottom()
    case .agent(let event):
      reduce(event)
    case .finished(let outcome):
      isRunning = false
      if outcome == .interrupted {
        transcript.append(TranscriptItem(kind: .notice, title: "Stopped", text: "Response interrupted."))
      }
      runTask = nil
      if let pending = pendingForceSend {
        pendingForceSend = nil
        submit(pending)
      }
      if isActive {
        wantsComposerFocus = true
      }
    case .failed(let message):
      isRunning = false
      transcript.append(TranscriptItem(kind: .error, title: "Error", text: message))
      runTask = nil
    }
    // The transcript ScrollView's sticksToBottom behavior follows new content
    // only when it was already at the bottom. Do not enqueue an unconditional
    // controller request here: streaming events would otherwise override a
    // user's attempt to scroll back through the response.
  }

  private func reduce(_ event: AgentEvent) {
    switch event {
    case .output(.sectionStarted(let section, _)):
      ensureStreamItem(section)
    case .output(.text(let section, let text)):
      append(text, to: section)
    case .output(.empty):
      transcript.append(TranscriptItem(kind: .notice, title: "Scribe", text: "Empty response."))
    case .output(.finalized):
      break
    case .tool(.invocation(let name, let arguments, let output)):
      upsertTool(name: name, arguments: arguments, output: output, running: false)
    case .tool(.warning(let warning)):
      transcript.append(TranscriptItem(kind: .warning, title: "Warning", text: warning))
    case .lifecycle(.usage(let usage, let rate)):
      var parts: [String] = []
      if let total = usage.totalTokens { parts.append("\(total) tokens") }
      if let rate { parts.append(String(format: "%.1f tok/s", rate)) }
      usageText = parts.joined(separator: " | ")
    case .lifecycle(.error(let error)):
      transcript.append(TranscriptItem(kind: .error, title: "Error", text: error.localizedDescription))
    case .lifecycle(.retrying(let attempt, let maxRetries, let delay, let reason)):
      transcript.append(
        TranscriptItem(
          kind: .warning, title: "Retrying",
          text:
            "\(reason) (attempt \(attempt)/\(maxRetries), delay: \(String(format: "%.1f", Double(delay.components.seconds) + Double(delay.components.attoseconds) / 1e18))s)"
        ))
    case .lifecycle(.interrupted):
      break
    case .lifecycle(.recovered(let reason)):
      transcript.append(TranscriptItem(kind: .warning, title: "Recovered", text: reason))
    case .boundary(.toolExecutionStart(let name, let arguments)):
      upsertTool(name: name, arguments: arguments, output: "", running: true)
    case .boundary(.toolExecutionEnd(let name, let output)):
      upsertTool(name: name, arguments: "", output: output, running: false)
    case .boundary:
      break
    }
  }

  private func ensureStreamItem(_ section: AssistantStreamSection) {
    let kind: ItemKind = section == .reasoning ? .reasoning : .answer
    if transcript.last?.kind != kind {
      transcript.append(
        TranscriptItem(
          kind: kind,
          title: section == .reasoning ? "Reasoning" : "Scribe",
          text: "",
          running: true))
    }
  }

  private func append(_ text: String, to section: AssistantStreamSection) {
    ensureStreamItem(section)
    transcript[transcript.count - 1].text += text
    transcript[transcript.count - 1].layoutRevision += 1
  }

  private func upsertTool(name: String, arguments: String, output: String, running: Bool) {
    if let index = transcript.lastIndex(where: { $0.kind == .tool && $0.title == name && $0.running }) {
      if !output.isEmpty {
        let lines = ToolInvocationFormatting.outputLines(name: name, jsonOutput: output)
        if !transcript[index].text.isEmpty, !lines.isEmpty {
          transcript[index].text += "\n"
        }
        transcript[index].text += lines.joined(separator: "\n")
      }
      transcript[index].running = running
      transcript[index].layoutRevision += 1
    } else {
      var sections: [String] = []
      if let summary = Self.argumentSummaryText(name: name, arguments: arguments) {
        sections.append(summary)
      }
      if !output.isEmpty {
        sections.append(
          ToolInvocationFormatting.outputLines(name: name, jsonOutput: output)
            .joined(separator: "\n"))
      }
      transcript.append(
        TranscriptItem(kind: .tool, title: name, text: sections.joined(separator: "\n"), running: running))
    }
  }

  /// Human-readable summary of a tool call's arguments (e.g. the shell
  /// command or file path), falling back to the raw JSON for tools without a
  /// known summary format.
  static func argumentSummaryText(name: String, arguments: String) -> String? {
    let trimmed = arguments.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    return ToolInvocationFormatting.argumentSummary(name: name, argumentsJSON: trimmed) ?? trimmed
  }

  private static func replay(_ messages: [ScribeMessage]) -> [TranscriptItem] {
    var result: [TranscriptItem] = []
    for message in messages {
      switch message.role {
      case .system:
        continue
      case .user:
        result.append(TranscriptItem(kind: .user, title: "You", text: message.content))
      case .assistant:
        if let reasoning = message.reasoning, !reasoning.isEmpty {
          result.append(TranscriptItem(kind: .reasoning, title: "Reasoning", text: reasoning))
        }
        if !message.content.isEmpty {
          result.append(TranscriptItem(kind: .answer, title: "Scribe", text: message.content))
        }
        for call in message.toolCalls ?? [] {
          result.append(
            TranscriptItem(
              kind: .tool, title: call.name,
              text: argumentSummaryText(name: call.name, arguments: call.arguments) ?? "",
              running: true))
        }
      case .tool:
        if let index = result.lastIndex(where: { $0.kind == .tool && $0.running }) {
          let lines = ToolInvocationFormatting.outputLines(
            name: result[index].title, jsonOutput: message.content)
          if !result[index].text.isEmpty, !lines.isEmpty {
            result[index].text += "\n"
          }
          result[index].text += lines.joined(separator: "\n")
          result[index].running = false
        } else {
          let name = message.name ?? "Tool"
          result.append(
            TranscriptItem(
              kind: .tool, title: name,
              text: ToolInvocationFormatting.outputLines(name: name, jsonOutput: message.content)
                .joined(separator: "\n")))
        }
      }
    }
    return result
  }
}
