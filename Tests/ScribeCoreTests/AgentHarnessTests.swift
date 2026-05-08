import Foundation
import HTTPTypes
import Logging
import OpenAPIRuntime
import ScribeCore
import ScribeLLM
import Testing

// MARK: - Fake Client Transport

/// A test transport that returns canned SSE byte chunks or error responses.
private struct FakeClientTransport: ClientTransport {
  let statusCode: Int
  let responseBodyChunks: [HTTPBody.ByteChunk]

  func send(
    _ request: HTTPRequest,
    body: HTTPBody?,
    baseURL: URL,
    operationID: String
  ) async throws -> (HTTPResponse, HTTPBody?) {
    let response = HTTPResponse(status: .init(code: statusCode))
    if responseBodyChunks.isEmpty {
      return (response, nil)
    }
    let body = HTTPBody(
      AsyncStream { continuation in
        for chunk in responseBodyChunks {
          continuation.yield(chunk)
        }
        continuation.finish()
      },
      length: .unknown
    )
    return (response, body)
  }
}

// MARK: - SSE chunk helpers

/// Builds a single SSE `data:` chunk from a JSON payload.
private func sseChunk(_ json: String) -> HTTPBody.ByteChunk {
  ArraySlice("data: \(json)\n\n".utf8)
}

/// The terminating SSE chunk that signals end-of-stream.
private func doneChunk() -> HTTPBody.ByteChunk {
  ArraySlice("data: [DONE]\n\n".utf8)
}

/// An error JSON body returned for non-200 responses.
private func errorBody(_ message: String) -> HTTPBody.ByteChunk {
  ArraySlice(#"{"error":{"message":"\#(message)"}}"#.utf8)
}

// MARK: - Sendable helpers

private final class EventCollector: @unchecked Sendable {
  var events: [TranscriptEvent] = []
  func append(_ event: TranscriptEvent) { events.append(event) }
}

// MARK: - Convenience

private func makeHarness(
  statusCode: Int = 200,
  chunks: [HTTPBody.ByteChunk],
  model: String = "test-model"
) -> AgentHarness {
  let transport = FakeClientTransport(statusCode: statusCode, responseBodyChunks: chunks)
  let client = Client(serverURL: URL(string: "http://test")!, transport: transport)
  return AgentHarness(client: client, model: model, tools: [])
}

private let testLogger = Logger(label: "test")

final class AbortState: @unchecked Sendable {
  var value = false
  func set(_ newValue: Bool) { value = newValue }
}

/// Helper to drain a stream and get the result.
private func awaitRound(_ rs: RoundStream, collector: EventCollector? = nil) async throws -> RoundResult {
  async let drain: Void = {
    if let c = collector {
      for await event in rs.events { c.append(event) }
    } else {
      for await _ in rs.events {}
    }
  }()
  let result = try await rs.result.value
  _ = await drain
  return result
}

// MARK: - Tests

@Suite
struct AgentHarnessTests {

  // MARK: - Successful responses

  @Test func completesWithAnswerText() async throws {
    let chunks = [
      sseChunk(
        #"{"id":"1","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"content":"Hello"}}]}"#
      ),
      sseChunk(
        #"{"id":"1","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"content":" world"}}]}"#
      ),
      sseChunk(
        #"{"id":"1","object":"chat.completion.chunk","choices":[],"usage":{"prompt_tokens":10,"completion_tokens":5,"total_tokens":15}}"#
      ),
      doneChunk(),
    ]
    let collector = EventCollector()
    let harness = makeHarness(chunks: chunks)

    let messages: [Components.Schemas.ChatMessage] = []
    let rs = harness.runRound(messages: messages, logger: testLogger, temperature: 0, shouldAbortTurn: { false })
    let result = try await awaitRound(rs, collector: collector)

    #expect(result.outcome == .completed)
    #expect(result.messages.count == 1)
    #expect(result.messages[0].role == .assistant)
    #expect(result.messages[0].content == "Hello world")

    let answerTexts = collector.events.compactMap {
      if case .appendAssistantText(.answer, let text) = $0 { text } else { nil }
    }
    #expect(answerTexts == ["Hello", " world"])

    let hasUsage = collector.events.contains {
      if case .usage = $0 { true } else { false }
    }
    #expect(hasUsage)

    let hasFinalize = collector.events.contains {
      if case .finalizeAssistantStream = $0 { true } else { false }
    }
    #expect(hasFinalize)
  }

  @Test func completesWithReasoningAndAnswer() async throws {
    let chunks = [
      sseChunk(
        #"{"id":"1","choices":[{"index":0,"delta":{"reasoning_content":"Let me think..."}}]}"#
      ),
      sseChunk(
        #"{"id":"1","choices":[{"index":0,"delta":{"content":"The answer is 42."}}]}"#
      ),
      doneChunk(),
    ]
    let collector = EventCollector()
    let harness = makeHarness(chunks: chunks)

    let messages: [Components.Schemas.ChatMessage] = []
    let rs = harness.runRound(messages: messages, logger: testLogger, temperature: 0, shouldAbortTurn: { false })
    let result = try await awaitRound(rs, collector: collector)

    #expect(result.outcome == .completed)
    #expect(result.messages[0].content == "The answer is 42.")
    #expect(result.messages[0].reasoningContent == "Let me think...")

    let sections = collector.events.compactMap {
      if case .enterAssistantSection(let section, _) = $0 { section } else { nil }
    }
    #expect(sections.first == .reasoning)
    #expect(sections.last == .answer)
  }

  @Test func resolvesToolCalls() async throws {
    let chunks = [
      sseChunk(
        #"{"id":"1","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call_1","type":"function","function":{"name":"shell","arguments":"ls"}}]}}]}"#
      ),
      sseChunk(
        #"{"id":"1","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":" -la"}}]}}]}"#
      ),
      doneChunk(),
    ]
    let harness = makeHarness(chunks: chunks)

    let messages: [Components.Schemas.ChatMessage] = []
    let rs = harness.runRound(messages: messages, logger: testLogger, temperature: 0, shouldAbortTurn: { false })
    let result = try await awaitRound(rs)

    guard case .toolCalls(let invocations) = result.outcome else {
      #expect(Bool(false), "expected toolCalls outcome")
      return
    }
    #expect(invocations.count == 1)
    #expect(invocations[0].name == "shell")
    #expect(invocations[0].arguments == "ls -la")
    #expect(result.messages[0].toolCalls?.count == 1)
  }

  @Test func skipsEmptyDataEvents() async throws {
    let chunks = [
      ArraySlice("data: \n\n".utf8),
      sseChunk(
        #"{"id":"1","choices":[{"index":0,"delta":{"content":"ok"}}]}"#
      ),
      sseChunk(
        #"{"id":"1","choices":[{"index":0,"delta":{"content":""}}]}"#
      ),
      doneChunk(),
    ]
    let harness = makeHarness(chunks: chunks)

    let messages: [Components.Schemas.ChatMessage] = []
    let rs = harness.runRound(messages: messages, logger: testLogger, temperature: 0, shouldAbortTurn: { false })
    let result = try await awaitRound(rs)

    #expect(result.outcome == .completed)
    #expect(result.messages[0].content == "ok")
  }

  // MARK: - Empty stream

  @Test func emptyStreamProducesEmptyAssistantTurn() async throws {
    let collector = EventCollector()
    let harness = makeHarness(chunks: [doneChunk()])

    let messages: [Components.Schemas.ChatMessage] = []
    let rs = harness.runRound(messages: messages, logger: testLogger, temperature: 0, shouldAbortTurn: { false })
    let result = try await awaitRound(rs, collector: collector)

    #expect(result.outcome == .completed)
    #expect(result.messages[0].content == "")
    #expect(result.messages[0].toolCalls == nil)

    let hasEmptyEvent = collector.events.contains {
      if case .emptyAssistantTurn = $0 { true } else { false }
    }
    #expect(hasEmptyEvent)
  }

  // MARK: - HTTP errors

  @Test func httpErrorNon200() async throws {
    let harness = makeHarness(statusCode: 500, chunks: [errorBody("Internal server error")])

    let messages: [Components.Schemas.ChatMessage] = []
    let rs = harness.runRound(messages: messages, logger: testLogger, temperature: 0, shouldAbortTurn: { false })
    do {
      _ = try await awaitRound(rs)
      #expect(Bool(false), "expected error")
    } catch let error as ScribeError {
      guard case .apiHTTPError(let code, _, _) = error else {
        #expect(Bool(false), "expected apiHTTPError")
        return
      }
      #expect(code == 500)
    }
  }

  @Test func httpError404() async throws {
    let harness = makeHarness(statusCode: 404, chunks: [errorBody("not found")])

    let messages: [Components.Schemas.ChatMessage] = []
    let rs = harness.runRound(messages: messages, logger: testLogger, temperature: 0, shouldAbortTurn: { false })
    do {
      _ = try await awaitRound(rs)
      #expect(Bool(false), "expected error")
    } catch let error as ScribeError {
      guard case .apiHTTPError(let code, _, let hint) = error else {
        #expect(Bool(false), "expected apiHTTPError")
        return
      }
      #expect(code == 404)
      #expect(hint?.isEmpty == false)
    }
  }

  @Test func httpErrorWithModelNotFoundHint() async throws {
    let harness = makeHarness(statusCode: 400, chunks: [errorBody("model not found")])

    let messages: [Components.Schemas.ChatMessage] = []
    let rs = harness.runRound(messages: messages, logger: testLogger, temperature: 0, shouldAbortTurn: { false })
    do {
      _ = try await awaitRound(rs)
      #expect(Bool(false), "expected error")
    } catch let error as ScribeError {
      guard case .apiHTTPError(_, _, let hint) = error else {
        #expect(Bool(false), "expected apiHTTPError")
        return
      }
      #expect(hint?.contains("model") == true)
    }
  }

  // MARK: - Unreadable chunks

  @Test func handlesUnreadableChunk() async throws {
    let collector = EventCollector()
    let chunks = [
      sseChunk(
        #"{"id":"1","choices":[{"index":0,"delta":{"content":"valid"}}]}"#
      ),
      ArraySlice("data: {bad json}\n\n".utf8),
      doneChunk(),
    ]
    let harness = makeHarness(chunks: chunks)

    let messages: [Components.Schemas.ChatMessage] = []
    let rs = harness.runRound(messages: messages, logger: testLogger, temperature: 0, shouldAbortTurn: { false })
    let result = try await awaitRound(rs, collector: collector)

    #expect(result.outcome == .completed)
    #expect(result.messages[0].content == "valid")

    let hasSkipped = collector.events.contains {
      if case .skippedUnreadableStreamLine = $0 { true } else { false }
    }
    #expect(hasSkipped)
  }

  // MARK: - Abort

  @Test func abortMidStream() async throws {
    let chunks = [
      sseChunk(
        #"{"id":"1","choices":[{"index":0,"delta":{"content":"Hello"}}]}"#
      ),
      sseChunk(
        #"{"id":"1","choices":[{"index":0,"delta":{"content":" world"}}]}"#
      ),
      doneChunk(),
    ]
    let harness = makeHarness(chunks: chunks)

    let abortState = AbortState()
    let messages: [Components.Schemas.ChatMessage] = []
    let rs = harness.runRound(
      messages: messages,
      logger: testLogger,
      temperature: 0,
      shouldAbortTurn: {
        if abortState.value { return true }
        abortState.set(true)
        return false
      }
    )
    do {
      _ = try await awaitRound(rs)
      #expect(Bool(false), "expected AgentTurnInterruptedError")
    } catch is AgentTurnInterruptedError {
      // Expected
    }
  }

  // MARK: - Token usage tracking

  @Test func reportsTokenUsageFromStream() async throws {
    let chunks = [
      sseChunk(
        #"{"id":"1","choices":[{"index":0,"delta":{"content":"x"}}]}"#
      ),
      sseChunk(
        #"{"id":"1","choices":[],"usage":{"prompt_tokens":20,"completion_tokens":10,"total_tokens":30}}"#
      ),
      doneChunk(),
    ]
    let collector = EventCollector()
    let harness = makeHarness(chunks: chunks)

    let messages: [Components.Schemas.ChatMessage] = []
    let rs = harness.runRound(messages: messages, logger: testLogger, temperature: 0, shouldAbortTurn: { false })
    _ = try await awaitRound(rs, collector: collector)

    let usageEvents = collector.events.compactMap {
      if case .usage(let u, let tps) = $0 { (u, tps) } else { nil }
    }
    #expect(usageEvents.count == 1)
    #expect(usageEvents[0].0.promptTokens == 20)
    #expect(usageEvents[0].0.completionTokens == 10)
    #expect(usageEvents[0].0.totalTokens == 30)
    #expect(usageEvents[0].1 != nil)
  }

  @Test func usageMissingWhenNoUsageChunk() async throws {
    let chunks = [
      sseChunk(
        #"{"id":"1","choices":[{"index":0,"delta":{"content":"no usage here"}}]}"#
      ),
      doneChunk(),
    ]
    let collector = EventCollector()
    let harness = makeHarness(chunks: chunks)

    let messages: [Components.Schemas.ChatMessage] = []
    let rs = harness.runRound(messages: messages, logger: testLogger, temperature: 0, shouldAbortTurn: { false })
    _ = try await awaitRound(rs, collector: collector)

    let hasUsage = collector.events.contains {
      if case .usage = $0 { true } else { false }
    }
    #expect(!hasUsage)
  }

  // MARK: - Tool call with content (hybrid)

  @Test func toolCallWithAnswerText() async throws {
    let chunks = [
      sseChunk(
        #"{"id":"1","choices":[{"index":0,"delta":{"content":"Let me check."}}]}"#
      ),
      sseChunk(
        #"{"id":"1","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call_1","type":"function","function":{"name":"shell","arguments":"pwd"}}]}}]}"#
      ),
      doneChunk(),
    ]
    let harness = makeHarness(chunks: chunks)

    let messages: [Components.Schemas.ChatMessage] = []
    let rs = harness.runRound(messages: messages, logger: testLogger, temperature: 0, shouldAbortTurn: { false })
    let result = try await awaitRound(rs)

    guard case .toolCalls = result.outcome else {
      #expect(Bool(false), "expected toolCalls")
      return
    }
    #expect(result.messages[0].content == "Let me check.")
  }

  // MARK: - Blank line event on completion

  @Test func emitsBlankLineOnCompletion() async throws {
    let chunks = [
      sseChunk(
        #"{"id":"1","choices":[{"index":0,"delta":{"content":"done"}}]}"#
      ),
      doneChunk(),
    ]
    let collector = EventCollector()
    let harness = makeHarness(chunks: chunks)

    let messages: [Components.Schemas.ChatMessage] = []
    let rs = harness.runRound(messages: messages, logger: testLogger, temperature: 0, shouldAbortTurn: { false })
    _ = try await awaitRound(rs, collector: collector)

    let hasBlankLine = collector.events.contains {
      if case .blankLine = $0 { true } else { false }
    }
    #expect(hasBlankLine)
  }

  // MARK: - Model name propagated

  @Test func usesConfiguredModelName() async throws {
    let chunks = [
      sseChunk(
        #"{"id":"1","model":"custom-model","choices":[{"index":0,"delta":{"content":"ok"}}]}"#
      ),
      doneChunk(),
    ]
    let harness = makeHarness(chunks: chunks, model: "custom-model")

    let messages: [Components.Schemas.ChatMessage] = []
    let rs = harness.runRound(messages: messages, logger: testLogger, temperature: 0, shouldAbortTurn: { false })
    let result = try await awaitRound(rs)

    #expect(result.messages[0].role == .assistant)
    #expect(harness.model == "custom-model")
  }
}
