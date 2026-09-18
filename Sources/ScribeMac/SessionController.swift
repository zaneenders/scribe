import Chroma
import Foundation
import Logging
import Observation
import ScribeCore
import ScribeKit

@MainActor
@Observable
final class SessionController {

  enum ItemKind: Sendable {
    case user
    case answer
    case reasoning
    case tool
    case notice
    case warning
    case error
  }

  struct TranscriptItem: Identifiable, Sendable {
    let id = UUID()
    var kind: ItemKind
    var title: String
    var text: String
    var running = false
    var layoutRevision = 0
    var isTextExpanded = false
    var sourceMessageIndex: Int?

    var layoutID: String {
      "transcript-row:\(id.uuidString):\(layoutRevision)"
    }

    var headerSelectionID: String {
      "transcript-selection:\(id.uuidString):header"
    }

    var selectionID: String {
      "transcript-selection:\(id.uuidString):body"
    }

    var selectionHeader: String {
      let marker =
        switch kind {
        case .user: ">"
        case .answer: "◆"
        case .reasoning: "◇"
        case .tool: "⌘"
        case .notice: "·"
        case .warning: "!"
        case .error: "×"
        }
      let displayedTitle = running ? "\(title) · running" : title
      return "\(marker) \(displayedTitle)"
    }

    var isCollapsible: Bool {
      guard kind == .user else { return false }
      var characters = 0
      var lines = 1
      for character in text {
        characters += 1
        if character == "\n" || character == "\r" || character == "\r\n" { lines += 1 }
        if characters > 1_000 || lines > 10 { return true }
      }
      return false
    }

    var isTextCollapsed: Bool { isCollapsible && !isTextExpanded }

    var displayText: String {
      guard isTextCollapsed else { return text }
      var preview = ""
      var lines = 1
      for character in text.prefix(240) {
        if character == "\n" || character == "\r" || character == "\r\n" {
          if lines == 3 { break }
          lines += 1
        }
        preview.append(character)
      }
      return preview + "\n[remaining text hidden]"
    }

    var selectionBody: String {
      text.isEmpty ? (running ? "running..." : "(empty)") : displayText
    }

    mutating func toggleTextDisclosure() {
      guard isCollapsible else { return }
      isTextExpanded.toggle()
      layoutRevision += 1
    }
  }

  private enum StreamEvent: Sendable {
    case userPrompt(String)
    case agent(AgentEvent)
    case finished(TurnOutcome)
    case failed(String)
  }

  enum SessionCommand: String, Sendable {
    case fork = "Fork"
    case tldr = "TLDR"
  }

  struct CommandPickerState: Sendable {
    var command: SessionCommand
    var boundaries: [Int]
    var startCursor: Int
    var endCursor: Int?
    var activeIsEnd: Bool
    var messageCount: Int
    var needsReveal = true

    var startBoundary: Int { boundaries[startCursor] }
    var endBoundary: Int { endCursor.map { boundaries[$0] } ?? startBoundary }
    var activeBoundary: Int { activeIsEnd ? endBoundary : startBoundary }
  }

  let boot: BootstrappedSession

  var transcript: [TranscriptItem]
  private(set) var isLoadingTranscript = false
  var draft = "" {
    didSet { draftRevision &+= 1 }
  }
  @ObservationIgnored private(set) var draftRevision: UInt64 = 0
  @ObservationIgnored let composerLayoutCache = ComposerTextLayoutCache()
  var isRunning = false
  private(set) var lastMessageAt: Date
  var usageText = ""
  var isActive = false
  var hasUnreadActivity = false
  var wantsComposerFocus = false
  let scroll = ScrollViewController()

  var profileName: String
  var modelName: String
  private(set) var sessionName: String?
  private(set) var isPinned: Bool
  private(set) var commandPicker: CommandPickerState?
  private(set) var isRunningCommand = false
  var onIdentityChange: ((UUID, UUID) -> Void)?
  var onRunningChange: ((Bool) -> Void)?

  private var currentSessionId: UUID
  private var runTask: Task<Void, Never>?
  private var promptHistory: [String]
  private var historyIndex: Int?
  private var draftBeforeHistory = ""
  private var pendingForceSend: String?

  var sessionId: UUID { currentSessionId }
  var workingDirectory: String { boot.workingDirectory }
  var queuedTexts: [String] { boot.messageQueue.previewTexts() }
  var sessionIdText: String { sessionId.uuidString.prefix(8).uppercased() }
  var displayName: String { sessionName ?? sessionIdText }
  var directoryTitle: String {
    if workingDirectory == "/" { return "/" }
    let last = (workingDirectory as NSString).lastPathComponent
    return last.isEmpty ? workingDirectory : last
  }

  init(boot: BootstrappedSession) {
    self.boot = boot
    self.profileName = boot.profile.name
    self.modelName = boot.profile.model
    let metadata = try? ChatSessionStore.loadMetadata(from: boot.sessionDirectory)
    self.sessionName = metadata?.name
    self.isPinned = metadata?.isPinned ?? false
    self.currentSessionId = boot.sessionId
    self.lastMessageAt = ChatSessionStore.lastMessageDate(
      in: boot.sessionDirectory, metadata: metadata)
    self.transcript = []
    self.promptHistory = boot.initialMessages.compactMap { message in
      message.role == .user && !message.content.isEmpty ? message.content : nil
    }
    let initialMessages = boot.initialMessages
    if initialMessages.count <= 40 {
      transcript = Self.replay(initialMessages)
    } else {
      isLoadingTranscript = true
      Task { [weak self] in
        let replayed = await Self.buildTranscript(initialMessages)
        guard let self else { return }
        self.transcript = replayed
        self.isLoadingTranscript = false
        self.scroll.scrollToBottom()
      }
    }
  }

  @concurrent
  private static func buildTranscript(_ messages: [ScribeMessage]) async -> [TranscriptItem] {
    replay(messages)
  }

  func applyPresentation(name: String?, isPinned: Bool) {
    sessionName = name
    self.isPinned = isPinned
  }

  func toggleTextDisclosure(id: UUID) {
    guard let index = transcript.firstIndex(where: { $0.id == id }) else { return }
    SelectionManager.shared.clear()
    transcript[index].toggleTextDisclosure()
  }

  func updateDraft(_ text: String) {
    draft = text
    historyIndex = nil
    draftBeforeHistory = ""
  }

  func insertComposerNewline() {
    draft.append("\n")
    historyIndex = nil
    draftBeforeHistory = ""
    ScribeMacStore.composerFocus.focus(editing: true)
  }

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
    ScribeMacStore.composerFocus.focus(editing: true)
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
    ScribeMacStore.composerFocus.focus(editing: true)
    return true
  }

  func openCommandPicker(_ command: SessionCommand) {
    guard !isRunning, !isRunningCommand else { return }
    commandPicker = nil
    Task {
      let snapshot = await boot.harness.snapshot()
      let boundaries = snapshot.safeForkBoundaries
      let minimumCount = command == .tldr ? 2 : 1
      guard boundaries.count >= minimumCount else {
        transcript.append(
          TranscriptItem(
            kind: .warning, title: command.rawValue,
            text: command == .tldr
              ? "TLDR needs at least two safe message boundaries."
              : "This session does not have a safe fork boundary yet."))
        scroll.scrollToBottom()
        return
      }
      let endCursor = boundaries.count - 1
      let startCursor: Int
      if command == .tldr {
        let lastUser = snapshot.messages.lastIndex { $0.role == .user }
        if let lastUser,
          let index = boundaries.firstIndex(of: lastUser + 1),
          index < endCursor
        {
          startCursor = index
        } else {
          startCursor = max(0, endCursor - 1)
        }
      } else {
        startCursor = endCursor
      }
      commandPicker = CommandPickerState(
        command: command, boundaries: boundaries, startCursor: startCursor,
        endCursor: command == .tldr ? endCursor : nil, activeIsEnd: false,
        messageCount: snapshot.count)
      ScribeRenderContext.current?.endEditing()
      transcript = Self.replay(snapshot.messages)
    }
  }

  func moveCommandCursor(by delta: Int) {
    guard !isRunningCommand, var picker = commandPicker else { return }
    if picker.activeIsEnd, let end = picker.endCursor {
      picker.endCursor = max(
        picker.startCursor + 1,
        min(picker.boundaries.count - 1, end + delta))
    } else {
      let upper =
        picker.command == .tldr
        ? (picker.endCursor ?? 1) - 1
        : picker.boundaries.count - 1
      picker.startCursor = max(0, min(upper, picker.startCursor + delta))
    }
    picker.needsReveal = true
    commandPicker = picker
  }

  func toggleCommandBoundary() {
    guard !isRunningCommand, var picker = commandPicker, picker.command == .tldr else { return }
    picker.activeIsEnd.toggle()
    picker.needsReveal = true
    commandPicker = picker
  }

  func consumeCommandReveal() -> Bool {
    guard var picker = commandPicker, picker.needsReveal else { return false }
    picker.needsReveal = false
    commandPicker = picker
    return true
  }

  func cancelCommandPicker() {
    guard !isRunningCommand else { return }
    commandPicker = nil
  }

  func confirmCommandPicker() {
    guard let picker = commandPicker, !isRunning, !isRunningCommand else { return }
    isRunningCommand = true
    Task {
      defer { isRunningCommand = false }
      do {
        let harness = boot.harness
        let snapshot = await harness.snapshot()
        let newId = UUID()
        let change: SessionIdentityChange?
        switch picker.command {
        case .fork:
          change = try await harness.applyEdit(
            .fork(cutAt: picker.startBoundary, newSessionId: newId))
        case .tldr:
          let start = picker.startBoundary
          let end = picker.endBoundary
          guard start >= 0, end <= snapshot.messages.count, start < end else {
            throw ScribeError.generic("The selected TLDR range is no longer valid.")
          }
          let configuration = await harness.configurationSnapshot()
          let summary = try await SessionSummarizer.summarize(
            slice: Array(snapshot.messages[start..<end]),
            configuration: configuration,
            sessionId: currentSessionId,
            logger: Logger(label: "scribe.mac.tldr"))
          change = try await harness.applyEdit(
            .forkSplice(
              startCut: start, endCut: end,
              replacement: [ScribeMessage(role: .assistant, content: summary)],
              newSessionId: newId))
        }
        if let change {
          let previous = currentSessionId
          currentSessionId = change.newSessionId
          onIdentityChange?(previous, change.newSessionId)
        }
        let updated = await harness.snapshot()
        transcript = Self.replay(updated.messages)
        transcript.append(
          TranscriptItem(
            kind: .notice, title: picker.command.rawValue,
            text: picker.command == .fork
              ? "Created a new session at message boundary \(picker.startBoundary)."
              : "Collapsed messages \(picker.startBoundary)-\(picker.endBoundary) into a summary."))
        commandPicker = nil
        lastMessageAt = Date()
        scroll.scrollToBottom()
      } catch {
        transcript.append(
          TranscriptItem(
            kind: .error, title: picker.command.rawValue,
            text: error.localizedDescription))
        scroll.scrollToBottom()
      }
    }
  }

  func submit(_ proposed: String? = nil) {
    guard commandPicker == nil, !isRunningCommand else { return }
    let text = proposed ?? draft
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
    if isRunning {
      enqueue(text)
      return
    }
    startTurn(text: text)
  }

  private func startTurn(text: String) {
    rememberPrompt(text)
    draft = ""
    historyIndex = nil
    draftBeforeHistory = ""
    isRunning = true
    onRunningChange?(true)

    let harness = boot.harness
    let (events, continuation) = AsyncStream<StreamEvent>.makeStream()
    runTask = Task { [weak self] in
      guard let self else { return }
      let consumer = Task { @MainActor [weak self] in
        for await event in events {
          self?.handle(event)
        }
      }
      defer {
        continuation.finish()
        _ = await consumer.result
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
    }
  }

  private func enqueue(_ text: String) {
    guard boot.messageQueue.enqueue(text: text) else { return }
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
    let queuedCount = boot.messageQueue.count()
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

  func forceSendNext() {
    guard let text = boot.messageQueue.popForRecall() else { return }
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
    let queue = boot.messageQueue
    let count = queue.count()
    queue.clear()
    return count
  }

  func shutdown(cancelTask: Bool) {
    boot.messageQueue.clear()
    Task { await boot.harness.interrupt() }
    if cancelTask {
      runTask?.cancel()
    }
    runTask = nil
  }

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
        serviceTier: loaded.scribeConfig.serviceTier,
        maxTokens: loaded.scribeConfig.maxTokens,
        sendsOpenCodeHeader: loaded.scribeConfig.sendsOpenCodeHeader,
        temperature: loaded.scribeConfig.temperature,
        maxRetries: loaded.scribeConfig.maxRetries
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

  private func handle(_ event: StreamEvent) {
    if !isActive {
      hasUnreadActivity = true
    }
    switch event {
    case .userPrompt(let text):
      lastMessageAt = Date()
      transcript.append(TranscriptItem(kind: .user, title: "You", text: text))
      scroll.scrollToBottom()
    case .agent(let event):
      lastMessageAt = Date()
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
      } else {
        onRunningChange?(false)
      }
      if isActive {
        wantsComposerFocus = true
      }
    case .failed(let message):
      isRunning = false
      onRunningChange?(false)
      transcript.append(TranscriptItem(kind: .error, title: "Error", text: message))
      runTask = nil
    }
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
    case .tool(.invocation):
      break
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

  nonisolated static func argumentSummaryText(name: String, arguments: String) -> String? {
    let trimmed = arguments.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    return ToolInvocationFormatting.argumentSummary(name: name, argumentsJSON: trimmed) ?? trimmed
  }

  nonisolated private static func replay(_ messages: [ScribeMessage]) -> [TranscriptItem] {
    var result: [TranscriptItem] = []
    for (messageIndex, message) in messages.enumerated() {
      switch message.role {
      case .system:
        continue
      case .user:
        result.append(
          TranscriptItem(
            kind: .user, title: "You", text: message.content,
            sourceMessageIndex: messageIndex))
      case .assistant:
        if let reasoning = message.reasoning, !reasoning.isEmpty {
          result.append(
            TranscriptItem(
              kind: .reasoning, title: "Reasoning", text: reasoning,
              sourceMessageIndex: messageIndex))
        }
        if !message.content.isEmpty {
          result.append(
            TranscriptItem(
              kind: .answer, title: "Scribe", text: message.content,
              sourceMessageIndex: messageIndex))
        }
        for call in message.toolCalls ?? [] {
          result.append(
            TranscriptItem(
              kind: .tool, title: call.name,
              text: argumentSummaryText(name: call.name, arguments: call.arguments) ?? "",
              running: true, sourceMessageIndex: messageIndex))
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
                .joined(separator: "\n"),
              sourceMessageIndex: messageIndex))
        }
      }
    }
    return result
  }
}
