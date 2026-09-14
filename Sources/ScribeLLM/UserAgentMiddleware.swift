import Foundation
import HTTPTypes
import OpenAPIRuntime

struct UserAgentMiddleware: ClientMiddleware {
  let value: String

  init(value: String = "Scribe") {
    self.value = value
  }

  func intercept(
    _ request: HTTPRequest,
    body: HTTPBody?,
    baseURL: URL,
    operationID: String,
    next: (HTTPRequest, HTTPBody?, URL) async throws -> (HTTPResponse, HTTPBody?)
  ) async throws -> (HTTPResponse, HTTPBody?) {
    var req = request
    req.headerFields[.userAgent] = value
    return try await next(req, body, baseURL)
  }
}
