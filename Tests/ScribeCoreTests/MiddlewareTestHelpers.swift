import Foundation
import HTTPTypes
import OpenAPIRuntime

let testRequest = HTTPRequest(method: .get, scheme: "https", authority: "api.example.com", path: "/")
let testBaseURL = URL(string: "https://api.example.com")!

// MARK: - Sendable capture helper

/// A reference type that allows an `@Sendable` closure to capture and mutate a value.
/// Safe because `intercept` invokes the `next` closure synchronously.
private final class Box<T>: @unchecked Sendable {
    var value: T?
    init(_ value: T? = nil) { self.value = value }
}

// MARK: - Driver

/// Captures the request that a middleware forwards to `next` so assertions
/// can inspect which headers the middleware added, removed, or preserved.
func interceptedRequest<M: ClientMiddleware>(
    through middleware: M,
    request: HTTPRequest = testRequest,
    baseURL: URL = testBaseURL
) async throws -> HTTPRequest {
    let box = Box<HTTPRequest>()
    let _ = try await middleware.intercept(
        request, body: nil, baseURL: baseURL, operationID: "test"
    ) { req, body, url in
        box.value = req
        return (HTTPResponse(status: .ok), nil)
    }
    // `intercept` calls the closure synchronously, so box.value is populated.
    return box.value!
}
