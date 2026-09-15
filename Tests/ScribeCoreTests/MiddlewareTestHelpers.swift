import Foundation
import HTTPTypes
import OpenAPIRuntime
import Synchronization

let testRequest = HTTPRequest(method: .get, scheme: "https", authority: "api.example.com", path: "/")
let testBaseURL = URL(string: "https://api.example.com")!

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
  return requestCapture.withLock { $0! }
}
