import Foundation
import HTTPTypes
import Logging
import OpenAPIRuntime
import ScribeCore
import ScribeKit
import ScribeLLM
import Synchronization
import SystemPackage

@testable import ScribeBlocks
@testable import ScribeCore

func replyChunks(_ text: String) -> [HTTPBody.ByteChunk] {
  [
    ArraySlice("data: {\"choices\":[{\"delta\":{\"content\":\"\(text)\"},\"finish_reason\":\"stop\"}]}\n\n".utf8),
    ArraySlice("data: [DONE]\n\n".utf8),
  ]
}

/// A `ClientTransport` whose responses are scripted per call, with optional
/// first-call gating or hanging so tests can observe an in-flight turn.
final class TestTransport: ClientTransport, Sendable {
  struct Response: Sendable {
    let chunks: [HTTPBody.ByteChunk]
  }

  private let responses: [Response]
  private let hangFirstCall: Bool
  private let gateFirstCall: Bool
  private let callIndex = Mutex(0)
  private let gate = Gate()
  private let signalContinuation: AsyncStream<Void>.Continuation
  private let signals: AsyncStream<Void>

  init(
    responses: [Response],
    hangFirstCall: Bool = false,
    gateFirstCall: Bool = false
  ) {
    self.responses = responses
    self.hangFirstCall = hangFirstCall
    self.gateFirstCall = gateFirstCall
    let (stream, continuation) = AsyncStream<Void>.makeStream()
    self.signals = stream
    self.signalContinuation = continuation
  }

  func openGate() {
    gate.open()
  }

  func waitForFirstRequest() async {
    var iterator = signals.makeAsyncIterator()
    _ = await iterator.next()
  }

  func send(
    _ request: HTTPRequest,
    body: HTTPBody?,
    baseURL: URL,
    operationID: String
  ) async throws -> (HTTPResponse, HTTPBody?) {
    if let body {
      for try await _ in body {}
    }
    let index = callIndex.withLock { state -> Int in
      let current = state
      state += 1
      return current
    }
    signalContinuation.yield()
    if index == 0 {
      if hangFirstCall { try await Task.sleep(for: .seconds(3600)) }
      if gateFirstCall { await gate.wait() }
    }

    let response = responses.isEmpty ? Response(chunks: []) : responses[min(index, responses.count - 1)]
    let httpResponse = HTTPResponse(status: .init(code: 200))
    let httpBody = HTTPBody(
      AsyncStream { continuation in
        for chunk in response.chunks { continuation.yield(chunk) }
        continuation.finish()
      },
      length: .unknown)
    return (httpResponse, httpBody)
  }
}

final class Gate: Sendable {
  private struct State {
    var isOpen = false
    var waiters: [CheckedContinuation<Void, Never>] = []
  }

  private let state = Mutex(State())

  func open() {
    let waiters = state.withLock { state -> [CheckedContinuation<Void, Never>] in
      state.isOpen = true
      let pending = state.waiters
      state.waiters = []
      return pending
    }
    for waiter in waiters { waiter.resume() }
  }

  func wait() async {
    await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        let resumeImmediately = state.withLock { state -> Bool in
          if state.isOpen { return true }
          state.waiters.append(continuation)
          return false
        }
        if resumeImmediately { continuation.resume() }
      }
    } onCancel: {
      open()
    }
  }
}

extension ScribeConfig {
  static let testValue = ScribeConfig(
    agentModel: "test-model",
    contextWindow: 4000,
    contextWindowThreshold: 0.75,
    serverURL: "http://test",
    apiKey: "test-token",
    workingDirectory: "/tmp",
    reasoningEnabled: nil
  )
}

extension SessionController.ItemKind {
  var testName: String {
    switch self {
    case .user: return "user"
    case .answer: return "answer"
    case .reasoning: return "reasoning"
    case .tool: return "tool"
    case .notice: return "notice"
    case .warning: return "warning"
    case .error: return "error"
    }
  }
}

func makeBoot(
  messages: [ScribeMessage] = [],
  sessionId: UUID = UUID(),
  transport: TestTransport,
  queue: SessionMessageQueue = SessionMessageQueue(),
  sessionDirectory: FilePath? = nil
) throws -> BootstrappedSession {
  let logger = Logger(label: "test.session-controller")
  let directory = sessionDirectory ?? FilePath("/in-memory/\(sessionId.uuidString)")
  let client = Client(serverURL: URL(string: "http://test")!, transport: transport)
  let agent = ScribeAgent(
    client: client,
    model: "test-model",
    workingDirectory: FilePath("/tmp"),
    reasoningEnabled: nil,
    logger: logger)
  var document = SessionDocument(
    sessionId: sessionId,
    directory: directory,
    logger: logger)
  document.append(messages)
  let harness = SessionHarness(
    configuration: .testValue,
    document: consume document,
    persister: InMemorySessionPersister(),
    agent: agent,
    logger: logger,
    messageQueue: queue)
  let profile = ProfileSummary(name: "default", model: "test-model", baseURL: "http://test")
  return BootstrappedSession(
    harness: harness,
    messageQueue: queue,
    initialMessages: messages,
    sessionId: sessionId,
    sessionDirectory: directory,
    profile: profile,
    profileCatalog: [profile],
    workingDirectory: "/tmp")
}

@MainActor
func makeController(
  transport: TestTransport,
  queue: SessionMessageQueue = SessionMessageQueue(),
  messages: [ScribeMessage] = [],
  sessionId: UUID = UUID(),
  sessionDirectory: FilePath? = nil
) throws -> SessionController {
  let boot = try makeBoot(
    messages: messages,
    sessionId: sessionId,
    transport: transport,
    queue: queue,
    sessionDirectory: sessionDirectory)
  return SessionController(boot: boot)
}

@MainActor
func waitUntil(
  timeout: Duration = .seconds(5),
  _ condition: @MainActor () -> Bool
) async -> Bool {
  let deadline = ContinuousClock.now + timeout
  while !condition() {
    if ContinuousClock.now >= deadline { return false }
    try? await Task.sleep(for: .milliseconds(5))
  }
  return true
}
