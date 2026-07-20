import Foundation
import HTTPTypes
import OpenAPIRuntime
import Synchronization

// MARK: - Scripted Transport

/// A scripted HTTP transport that returns pre-configured responses.
///
/// Responses are consumed in order. If more calls are made than there are
/// responses, the last response is replayed. Request bodies are captured
/// and available via ``requestBodies``.
final class ScriptedTransport: ClientTransport, Sendable {
    struct Response: Sendable {
        let status: Int
        let chunks: [HTTPBody.ByteChunk]

        init(status: Int, chunks: [HTTPBody.ByteChunk]) {
            self.status = status
            self.chunks = chunks
        }

        /// A response with status 200 and no body.
        static let empty = Response(status: 200, chunks: [])
    }

    private let responses: [Response]
    private let state: Mutex<State>
    private let capturedBodies: Mutex<[Data]>

    private struct State {
        var callIndex = 0
    }

    /// All captured request bodies, in call order.
    var requestBodies: [Data] {
        capturedBodies.withLock { $0 }
    }

    init(responses: [Response]) {
        self.responses = responses
        self.state = Mutex(State())
        self.capturedBodies = Mutex([])
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
        if let body = body {
            var data = Data()
            for try await chunk in body {
                data.append(contentsOf: chunk)
            }
            capturedBodies.withLock { $0.append(data) }
        }

        let (statusCode, chunks) = state.withLock { state -> (Int, [HTTPBody.ByteChunk]) in
            let idx = state.callIndex
            state.callIndex += 1
            if idx < responses.count {
                let r = responses[idx]
                return (r.status, r.chunks)
            }
            return responses.last.map { ($0.status, $0.chunks) } ?? (200, [])
        }

        let response = HTTPResponse(status: .init(code: statusCode))
        if chunks.isEmpty { return (response, nil) }
        let responseBody = HTTPBody(
            AsyncStream { continuation in
                for chunk in chunks { continuation.yield(chunk) }
                continuation.finish()
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
