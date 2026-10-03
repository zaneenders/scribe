import Foundation
import HTTPTypes
import OpenAPIRuntime
import ScribeCodexAuth

struct CodexAuthMiddleware: ClientMiddleware {
  let token: String?
  let accountID: String?
  let credentials: (@Sendable (String?) async throws -> CodexAccessCredential)?

  init(token: String?, accountID: String?) {
    self.token = token
    self.accountID = accountID
    self.credentials = nil
  }

  init(credentials: @escaping @Sendable (String?) async throws -> CodexAccessCredential) {
    self.token = nil
    self.accountID = nil
    self.credentials = credentials
  }

  func intercept(
    _ request: HTTPRequest,
    body: HTTPBody?,
    baseURL: URL,
    operationID: String,
    next: (HTTPRequest, HTTPBody?, URL) async throws -> (HTTPResponse, HTTPBody?)
  ) async throws -> (HTTPResponse, HTTPBody?) {
    guard
      baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        == "https://chatgpt.com/backend-api",
      request.path == "/responses", request.scheme == nil || request.scheme == "https",
      request.authority == nil || request.authority == "chatgpt.com"
    else { throw URLError(.badURL) }
    guard let credentials else {
      return try await next(authenticated(request, token: token, accountID: accountID), body, baseURL)
    }

    let credential = try await credentials(nil)
    let response = try await next(
      authenticated(request, token: credential.access, accountID: credential.accountId), body, baseURL)
    guard response.0.status.code == 401 else { return response }
    // Generated JSON request bodies are replayable. Never retry a consumed stream.
    guard body == nil || body?.iterationBehavior == .multiple else {
      throw CodexOAuthError.loginRequired
    }
    if let errorBody = response.1 {
      _ = try? await HTTPBody.ByteChunk(collecting: errorBody, upTo: 4096)
    }
    let refreshed = try await credentials(credential.access)
    guard refreshed.accountId == credential.accountId else { throw CodexOAuthError.loginRequired }
    let retried = try await next(
      authenticated(request, token: refreshed.access, accountID: refreshed.accountId), body, baseURL)
    guard retried.0.status.code != 401 else { throw CodexOAuthError.loginRequired }
    return retried
  }

  private func authenticated(_ request: HTTPRequest, token: String?, accountID: String?) -> HTTPRequest {
    var req = request
    if let path = req.path {
      req.path = path.replacingOccurrences(of: "/responses", with: "/codex/responses")
    }
    if let token, !token.isEmpty {
      req.headerFields[.authorization] = "Bearer \(token)"
    }
    if let accountID, !accountID.isEmpty {
      req.headerFields[.init("chatgpt-account-id")!] = accountID
    }
    if req.headerFields[.init("originator")!] == nil {
      req.headerFields[.init("originator")!] = "pi"
    }
    return req
  }
}
