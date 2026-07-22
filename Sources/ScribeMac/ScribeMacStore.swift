import Chroma
import Foundation
import ScribeCore
import ScribeKit

@MainActor
final class ScribeMacStore {
  enum Phase {
    case starting
    case ready
    case failed(String)
  }

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

  static let shared = ScribeMacStore()
  static let composerID = WidgetID("scribe-composer")

  var phase: Phase = .starting
  var draft = ""
  var transcript: [TranscriptItem] = []
  var isRunning = false
  var profileName = ""
  var modelName = ""
  var workingDirectory = ""
  var usageText = ""
  var sessionIdText: String { session?.sessionId.uuidString.prefix(8).uppercased() ?? "" }
  /// Messages queued while a turn is running, oldest first.
  var queuedTexts: [String] { session?.messageQueues.steeringPreviewTexts() ?? [] }
  let transcriptScroll = ScrollViewController()

  /// Available profiles for model switching.
  var profileCatalog: [ProfileSummary] = []
  /// Whether the model picker overlay is visible.
  var showModelPicker = false

  private var session: BootstrappedSession?
  private var runTask: Task<Void, Never>?
  private var didStart = false
  private var composerFocusPending = false

  private init() {}

  func start() {
    guard !didStart else { return }
    didStart = true
    Task {
      do {
        try ShellCaptureDirectory.setup(dataHome: ScribePaths.resolve().dataHomePath)
        let opened = try await ScribeSessionBootstrap.open(version: GitVersion.hash)
        install(opened)
      } catch {
        phase = .failed(error.localizedDescription)
      }
    }
  }

  func newSession() {
    guard !isRunning else { return }
    phase = .starting
    Task {
      do {
        let opened = try await ScribeSessionBootstrap.open(version: GitVersion.hash)
        install(opened)
      } catch {
        phase = .failed(error.localizedDescription)
      }
    }
  }

  func resumeLatest() {
    guard !isRunning else { return }
    phase = .starting
    Task {
      do {
        let opened = try await ScribeSessionBootstrap.open(
          resumeLatest: true,
          version: GitVersion.hash)
        install(opened)
      } catch {
        phase = .failed(error.localizedDescription)
      }
    }
  }

  private func install(_ opened: BootstrappedSession) {
    session = opened
    profileName = opened.profile.name
    modelName = opened.profile.model
    profileCatalog = opened.profileCatalog
    workingDirectory = opened.workingDirectory
    transcript = Self.replay(opened.initialMessages)
    usageText = ""
    phase = .ready
    transcriptScroll.scrollToBottom()
    composerFocusPending = true
  }

  /// Focus must be requested after a frame has registered the composer leaf.
  func applyPendingFocus() {
    guard composerFocusPending else { return }
    Interaction.current.focus(Self.composerID, editing: true)
    if Interaction.current.isTextEditing {
      composerFocusPending = false
    }
  }

  // MARK: - Model picker

  func toggleModelPicker() {
    guard !isRunning else { return }
    showModelPicker.toggle()
  }

  func selectProfile(_ name: String) {
    showModelPicker = false
    guard name != profileName else { return }
    Task { await applyModelProfile(name) }
  }

  private func applyModelProfile(_ name: String) async {
    let previousName = profileName
    do {
      let loaded = try await ConfigLoader.load(profileOverride: name)
      guard let harness = session?.harness else { return }
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
      try await harness.reconfigure(configuration: newConfig)
      profileName = loaded.activeProfileName
      modelName = loaded.scribeConfig.agentModel
      profileCatalog = loaded.profiles
      let message: String
      if name == previousName {
        message = "Model reloaded: \(name) (\(modelName))"
      } else {
        message = "Switched to \(name) (\(modelName))"
      }
      transcript.append(TranscriptItem(kind: .notice, title: "Model", text: message))
      transcriptScroll.scrollToBottom()
    } catch {
      transcript.append(
        TranscriptItem(
          kind: .error, title: "Error",
          text: "Could not switch model: \(error.localizedDescription)"))
    }
  }

  func submit(_ proposed: String? = nil) {
    let text = (proposed ?? draft).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return }
    if isRunning {
      enqueue(text)
      return
    }
    guard let harness = session?.harness else { return }
    draft = ""
    isRunning = true

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
    guard let queues = session?.messageQueues else { return }
    guard queues.enqueueSteering(text: text) else { return }
    draft = ""
  }

  func stop() {
    guard isRunning, let harness = session?.harness else { return }
    // Interrupting alone would let the harness dispatch queued steering
    // messages into a fresh turn, so Stop also drops the pending queue.
    let dropped = discardQueuedMessages()
    if dropped > 0 {
      transcript.append(
        TranscriptItem(
          kind: .notice, title: "Queue",
          text: "Discarded \(dropped) queued message\(dropped == 1 ? "" : "s")."))
    }
    Task { await harness.interrupt() }
  }

  func clearQueue() {
    let dropped = discardQueuedMessages()
    guard dropped > 0 else { return }
    transcript.append(
      TranscriptItem(
        kind: .notice, title: "Queue",
        text: "Cleared \(dropped) queued message\(dropped == 1 ? "" : "s")."))
    transcriptScroll.scrollToBottom()
  }

  @discardableResult
  private func discardQueuedMessages() -> Int {
    guard let queues = session?.messageQueues else { return 0 }
    let count = queues.steeringCount() + queues.followUpCount()
    queues.clearAll()
    return count
  }

  func close() {
    let harness = session?.harness
    session?.messageQueues.clearAll()
    runTask?.cancel()
    runTask = nil
    if let harness {
      Task { await harness.interrupt() }
    }
    ShellCaptureDirectory.teardown()
  }

  private func handle(_ event: StreamEvent) {
    switch event {
    case .userPrompt(let text):
      // Echoes both the submitted message and queued messages as the harness
      // dispatches them at the start of each turn.
      transcript.append(TranscriptItem(kind: .user, title: "You", text: text))
      transcriptScroll.scrollToBottom()
    case .agent(let event): reduce(event)
    case .finished(let outcome):
      isRunning = false
      if outcome == .interrupted {
        transcript.append(TranscriptItem(kind: .notice, title: "Stopped", text: "Response interrupted."))
      }
      runTask = nil
      composerFocusPending = true
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
      transcript.append(TranscriptItem(
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
      if !arguments.isEmpty { transcript[index].text = arguments }
      if !output.isEmpty {
        if !transcript[index].text.isEmpty { transcript[index].text += "\n\n" }
        transcript[index].text += output
      }
      transcript[index].running = running
      transcript[index].layoutRevision += 1
    } else {
      let text = [arguments, output].filter { !$0.isEmpty }.joined(separator: "\n\n")
      transcript.append(TranscriptItem(kind: .tool, title: name, text: text, running: running))
    }
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
          result.append(TranscriptItem(
            kind: .tool, title: call.name, text: call.arguments, running: true))
        }
      case .tool:
        if let index = result.lastIndex(where: { $0.kind == .tool && $0.running }) {
          if !result[index].text.isEmpty { result[index].text += "\n\n" }
          result[index].text += message.content
          result[index].running = false
        } else {
          result.append(TranscriptItem(
            kind: .tool, title: message.name ?? "Tool", text: message.content))
        }
      }
    }
    return result
  }
}
