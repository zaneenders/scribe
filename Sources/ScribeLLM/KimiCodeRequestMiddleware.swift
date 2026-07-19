import Foundation
import HTTPTypes
import OpenAPIRuntime

/// Kimi Code requires a recognized coding-agent identity on every request.
struct KimiCodeRequestMiddleware: ClientMiddleware, Sendable {
  private let headerFields: [(HTTPField.Name, String)]

  init(headers: [String: String]) {
    self.headerFields = headers.map { (HTTPField.Name($0.key)!, $0.value) }
  }

  func intercept(
    _ request: HTTPRequest,
    body: HTTPBody?,
    baseURL: URL,
    operationID: String,
    next: (HTTPRequest, HTTPBody?, URL) async throws -> (HTTPResponse, HTTPBody?)
  ) async throws -> (HTTPResponse, HTTPBody?) {
    guard baseURL.host()?.contains("kimi.com") == true else {
      return try await next(request, body, baseURL)
    }
    var req = request
    for (name, value) in headerFields {
      req.headerFields[name] = value
    }
    return try await next(req, body, baseURL)
  }
}
