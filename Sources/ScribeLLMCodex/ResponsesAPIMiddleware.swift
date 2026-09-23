import Foundation
import HTTPTypes
import OpenAPIRuntime

struct ResponsesAPIMiddleware: ClientMiddleware {
  let apiKey: String?

  func intercept(
    _ request: HTTPRequest,
    body: HTTPBody?,
    baseURL: URL,
    operationID: String,
    next: (HTTPRequest, HTTPBody?, URL) async throws -> (HTTPResponse, HTTPBody?)
  ) async throws -> (HTTPResponse, HTTPBody?) {
    var request = request
    if let path = request.path {
      request.path = path.replacingOccurrences(of: "/codex/responses", with: "/responses")
    }
    if let apiKey, !apiKey.isEmpty {
      request.headerFields[.authorization] = "Bearer \(apiKey)"
    }
    return try await next(request, body, baseURL)
  }
}
