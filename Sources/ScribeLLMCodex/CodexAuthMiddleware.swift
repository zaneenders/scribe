import Foundation
import HTTPTypes
import OpenAPIRuntime

/// Middleware that injects both the Bearer token and the
/// `chatgpt-account-id` header required by the ChatGPT
/// subscription (Codex) backend API.
struct CodexAuthMiddleware: ClientMiddleware {
  let token: String?
  let accountID: String?

  init(token: String?, accountID: String?) {
    self.token = token
    self.accountID = accountID
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
    if let accountID, !accountID.isEmpty {
      req.headerFields[.init("chatgpt-account-id")!] = accountID
    }
    // Identify as the pi/Codex CLI originator (required by the backend)
    if req.headerFields[.init("originator")!] == nil {
      req.headerFields[.init("originator")!] = "pi"
    }
    return try await next(req, body, baseURL)
  }
}
