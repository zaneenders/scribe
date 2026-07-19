import Foundation
import HTTPTypes
import OpenAPIRuntime

/// Sets `x-api-key` and `anthropic-version` headers on every request.
struct AnthropicAuthMiddleware: ClientMiddleware, Sendable {
  private let apiKey: String?
  private let anthropicVersion: String

  init(apiKey: String?, anthropicVersion: String) {
    self.apiKey = apiKey
    self.anthropicVersion = anthropicVersion
  }

  func intercept(
    _ request: HTTPRequest,
    body: HTTPBody?,
    baseURL: URL,
    operationID: String,
    next: (HTTPRequest, HTTPBody?, URL) async throws -> (HTTPResponse, HTTPBody?)
  ) async throws -> (HTTPResponse, HTTPBody?) {
    var req = request
    if let apiKey, !apiKey.isEmpty {
      req.headerFields[.init("x-api-key")!] = apiKey
    }
    req.headerFields[.init("anthropic-version")!] = anthropicVersion
    return try await next(req, body, baseURL)
  }
}
