import Foundation
import HTTPTypes
import OpenAPIRuntime

/// Sets `Authorization: Bearer` on Kimi Code requests. Omits `anthropic-version`.
struct KimiCodeAuthMiddleware: ClientMiddleware, Sendable {
  private let token: String?

  init(token: String?) {
    self.token = token
  }

  func intercept(
    _ request: HTTPRequest,
    body: HTTPBody?,
    baseURL: URL,
    operationID: String,
    next: (HTTPRequest, HTTPBody?, URL) async throws -> (HTTPResponse, HTTPBody?)
  ) async throws -> (HTTPResponse, HTTPBody?) {
    var req = request
    if let token, !token.isEmpty {
      req.headerFields[.authorization] = "Bearer \(token)"
    }
    return try await next(req, body, baseURL)
  }
}
