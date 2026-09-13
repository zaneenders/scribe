import Foundation
import HTTPTypes
import OpenAPIRuntime
import Synchronization

let testRequest = HTTPRequest(method: .get, scheme: "https", authority: "api.example.com", path: "/")
let testBaseURL = URL(string: "https://api.example.com")!

// MARK: - Driver

/// Captures the request that a middleware forwards to `next` so assertions
/// can inspect which headers the middleware added, removed, or preserved.
func interceptedRequest<M: ClientMiddleware>(
  through middleware: M,
  request: HTTPRequest = testRequest,
  baseURL: URL = testBaseURL
) async throws -> HTTPRequest {
  let requestCapture = Mutex<HTTPRequest?>(nil)
  let _ = try await middleware.intercept(
    request, body: nil, baseURL: baseURL, operationID: "test"
  ) { req, body, url in
    requestCapture.withLock { $0 = req }
    return (HTTPResponse(status: .ok), nil)
  }
  // Read the request after the middleware has completed.
  return requestCapture.withLock { $0! }
}
