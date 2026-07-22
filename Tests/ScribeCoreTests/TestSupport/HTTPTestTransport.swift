import Foundation
import HTTPTypes
import OpenAPIRuntime
import Synchronization

// MARK: - Captured Request

/// A snapshot of an HTTP request made through ``ScriptedTransport``.
public struct CapturedRequest: Sendable {
  public let method: HTTPRequest.Method
  public let path: String
  public let baseURL: URL
  public let operationID: String
  public let headers: HTTPFields
  public let body: Data?

  public init(
    method: HTTPRequest.Method,
    path: String,
    baseURL: URL,
    operationID: String,
    headers: HTTPFields,
    body: Data?
  ) {
    self.method = method
    self.path = path
    self.baseURL = baseURL
    self.operationID = operationID
    self.headers = headers
    self.body = body
  }
}

// MARK: - Scripted Transport

/// A scripted HTTP transport that returns pre-configured responses.
///
/// Responses are consumed in order. If more calls are made than there are
/// responses, the last response is replayed. Every request is captured and
/// available via ``capturedRequests`` for full endpoint / header assertions.
final class ScriptedTransport: ClientTransport, Sendable {
  struct Response: Sendable {
    let status: Int
    let chunks: [HTTPBody.ByteChunk]
    /// When set, `send` throws this error instead of producing a response, simulating
    /// a transport-level failure such as a dropped connection.
    let error: (any Error)?
    /// When set, the response body fails with this error after every chunk has been
    /// delivered, simulating a mid-stream disconnect.
    let streamError: (any Error)?

    init(
      status: Int,
      chunks: [HTTPBody.ByteChunk],
      error: (any Error)? = nil,
      streamError: (any Error)? = nil
    ) {
      self.status = status
      self.chunks = chunks
      self.error = error
      self.streamError = streamError
    }

    /// A response with status 200 and no body.
    static let empty = Response(status: 200, chunks: [])
  }

  private let responses: [Response]
  private let state: Mutex<State>
  private let captured: Mutex<[CapturedRequest]>

  private struct State {
    var callIndex = 0
  }

  /// All captured requests, in call order.
  var capturedRequests: [CapturedRequest] {
    captured.withLock { $0 }
  }

  /// Backward-compatible accessor for request bodies only.
  var requestBodies: [Data] {
    captured.withLock { $0.compactMap(\.body) }
  }

  init(responses: [Response]) {
    self.responses = responses
    self.state = Mutex(State())
    self.captured = Mutex([])
  }

  /// Convenience initializer for a single response.
  convenience init(status: Int = 200, chunks: [HTTPBody.ByteChunk] = []) {
    self.init(responses: [Response(status: status, chunks: chunks)])
  }

  func send(
    _ request: HTTPRequest,
    body: HTTPBody?,
    baseURL: URL,
    operationID: String
  ) async throws -> (HTTPResponse, HTTPBody?) {
    // Capture the request body
    var bodyData: Data? = nil
    if let body = body {
      var data = Data()
      for try await chunk in body {
        data.append(contentsOf: chunk)
      }
      bodyData = data
    }

    captured.withLock {
      $0.append(
        CapturedRequest(
          method: request.method,
          path: request.path ?? "",
          baseURL: baseURL,
          operationID: operationID,
          headers: request.headerFields,
          body: bodyData
        )
      )
    }

    let scripted = state.withLock { state -> Response in
      let idx = state.callIndex
      state.callIndex += 1
      if idx < responses.count {
        return responses[idx]
      }
      return responses.last ?? Response(status: 200, chunks: [])
    }
    if let error = scripted.error { throw error }

    let response = HTTPResponse(status: .init(code: scripted.status))
    if scripted.chunks.isEmpty && scripted.streamError == nil { return (response, nil) }
    let responseBody = HTTPBody(
      AsyncThrowingStream { continuation in
        for chunk in scripted.chunks { continuation.yield(chunk) }
        if let streamError = scripted.streamError {
          continuation.finish(throwing: streamError)
        } else {
          continuation.finish()
        }
      }, length: .unknown)
    return (response, responseBody)
  }
}

// MARK: - Hanging Transport

/// A transport that hangs indefinitely (for timeout / cancellation testing).
final class HangingClientTransport: ClientTransport, Sendable {
  func send(
    _ request: HTTPRequest,
    body: HTTPBody?,
    baseURL: URL,
    operationID: String
  ) async throws -> (HTTPResponse, HTTPBody?) {
    try await Task.sleep(for: .seconds(3600))
    return (HTTPResponse(status: .init(code: 200)), nil)
  }
}
