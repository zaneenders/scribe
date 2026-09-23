import Foundation
import HTTPTypes
import Logging
import OpenAPIRuntime
import ScribeCore
import ScribeLLM
import SystemPackage
import Synchronization
import Testing

@testable import ScribeKit

/// A `ClientTransport` whose responses are scripted per call. Supports
/// hanging a specific call (until cancelled, e.g. by interrupt) and polling
/// the number of started calls so tests can synchronize with in-flight turns.
final class ScriptedSSETransport: ClientTransport, Sendable {

  private struct State {
    var callIndex = 0
    var hangCallIDs: Set<Int> = []
  }

  private let state = Mutex(State())
  private let replies: Mutex<[String]>

  init(replies: [String] = ["ok"]) {
    self.replies = Mutex(replies)
  }

  /// Makes the next HTTP call hang until cancelled.
  func hangNextCall() {
    _ = state.withLock { $0.hangCallIDs.insert($0.callIndex) }
  }

  func callCount() -> Int {
    state.withLock { $0.callIndex }
  }

  func waitForCallCount(
    _ count: Int, timeout: Duration = .seconds(5)
  ) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while callCount() < count {
      if ContinuousClock.now >= deadline { return false }
      try? await Task.sleep(for: .milliseconds(5))
    }
    return true
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
    let index = state.withLock { state -> Int in
      let current = state.callIndex
      state.callIndex += 1
      return current
    }
    let shouldHang = state.withLock { $0.hangCallIDs.contains(index) }
    if shouldHang {
      try await Task.sleep(for: .seconds(3600))
    }
    let reply = replies.withLock { $0[min(index, $0.count - 1)] }
    let payload =
      "data: {\"choices\":[{\"delta\":{\"content\":\"\(reply)\"},\"finish_reason\":\"stop\"}]}\n\n"
      + "data: [DONE]\n\n"
    let httpBody = HTTPBody(
      AsyncStream { continuation in
        continuation.yield(ArraySlice(payload.utf8))
        continuation.finish()
      },
      length: .unknown)
    return (HTTPResponse(status: .init(code: 200)), httpBody)
  }
}

/// Fixture running the shared contract scenarios against
/// `LocalScribeSessionService` over a temporary home with a scripted agent
/// runtime. All service instances created from one fixture share the home and
/// the transport, so reconstruction scenarios work.
struct LocalServiceFixture: ScribeServiceContractFixture {

  let root: FilePath
  let context: ScribeRuntimeContext
  let transport: ScriptedSSETransport

  init(
    root: FilePath,
    replies: [String] = ["ok", "ok", "ok", "ok", "ok", "ok", "ok", "ok"]
  ) throws {
    self.root = root
    let paths = ScribePaths(dataHome: root)
    try createDirectoryWithIntermediates(root)
    let configJSON = """
      {
        "profiles": [
          {
            "name": "alpha",
            "api": { "baseUrl": "http://test", "apiKey": "" },
            "agent": { "model": "model-alpha", "contextWindow": 4000, "contextWindowThreshold": 0.75 },
            "logging": { "level": "trace" }
          },
          {
            "name": "beta",
            "api": { "baseUrl": "http://test", "apiKey": "" },
            "agent": { "model": "model-beta", "contextWindow": 4000, "contextWindowThreshold": 0.75 },
            "logging": { "level": "trace" }
          }
        ]
      }
      """
    try configJSON.write(
      toFile: paths.profileManifestPath.string, atomically: true, encoding: .utf8)
    self.context = ScribeRuntimeContext(
      paths: paths,
      configurationFile: paths.profileManifestPath,
      defaultWorkingDirectory: "/tmp",
      version: "local-service-test")
    self.transport = ScriptedSSETransport(replies: replies)
  }

  func makeService() async throws -> LocalScribeSessionService {
    let transport = self.transport
    let client = Client(serverURL: URL(string: "http://test")!, transport: transport)
    return LocalScribeSessionService(
      context: context,
      agentFactory: { configuration, logger in
        ScribeAgent(
          client: client,
          model: configuration.agentModel,
          workingDirectory: FilePath(configuration.workingDirectory),
          reasoningEnabled: nil,
          logger: logger)
      })
  }

  func startBlockedTurn(
    _ service: LocalScribeSessionService,
    sessionID: UUID,
    prompt: String
  ) async throws -> AsyncThrowingStream<ScribeSessionEvent, any Error> {
    let callsBefore = transport.callCount()
    transport.hangNextCall()
    let stream = try await service.submit(
      ScribeSubmitRequest(sessionID: sessionID, prompt: prompt))
    // Deterministically wait until the scripted call is in flight.
    _ = await transport.waitForCallCount(callsBefore + 1)
    return stream
  }

  func finishBlockedTurn(_ service: LocalScribeSessionService, sessionID: UUID) async throws {
    try await service.interrupt(sessionID: sessionID)
  }
}

func withLocalServiceFixture<T>(
  replies: [String] = ["ok", "ok", "ok", "ok", "ok", "ok", "ok", "ok"],
  _ body: (LocalServiceFixture) async throws -> T
) async throws -> T {
  try await withTemporaryDirectory { root in
    let fixture = try LocalServiceFixture(root: FilePath(root.path), replies: replies)
    return try await body(fixture)
  }
}
