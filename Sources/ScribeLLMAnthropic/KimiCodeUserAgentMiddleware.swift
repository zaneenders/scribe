import Foundation
import HTTPTypes
import OpenAPIRuntime

/// Kimi Code requires a recognized coding-agent User-Agent.
struct KimiCodeUserAgentMiddleware: ClientMiddleware, Sendable {
  private let userAgent: String

  init(userAgent: String = "KimiCLI/1.0") {
    self.userAgent = userAgent
  }

  func intercept(
    _ request: HTTPRequest,
    body: HTTPBody?,
    baseURL: URL,
    operationID: String,
    next: (HTTPRequest, HTTPBody?, URL) async throws -> (HTTPResponse, HTTPBody?)
  ) async throws -> (HTTPResponse, HTTPBody?) {
    var req = request
    if baseURL.host()?.contains("kimi.com") == true {
      req.headerFields[.userAgent] = userAgent
    }
    return try await next(req, body, baseURL)
  }
}
