import Foundation
import HTTPTypes
import OpenAPIRuntime
import Testing

@testable import ScribeLLM

@Suite
struct BearerTokenMiddlewareTests {
  @Test
  func addsAuthorizationHeaderWhenTokenPresent() async throws {
    let middleware = BearerTokenMiddleware(token: "sk-abc123")
    let request = HTTPRequest(method: .get, scheme: "https", authority: "api.example.com", path: "/v1/chat")

    _ = try await middleware.intercept(request, body: nil, baseURL: URL(string: "https://api.example.com")!, operationID: "test") { req, body, url in
      #expect(req.headerFields[.authorization] == "Bearer sk-abc123")
      return (HTTPResponse(status: .ok), nil)
    }
  }

  @Test
  func addsNoHeaderWhenTokenIsNil() async throws {
    let middleware = BearerTokenMiddleware(token: nil)
    let request = HTTPRequest(method: .get, scheme: "https", authority: "api.example.com", path: "/v1/chat")

    _ = try await middleware.intercept(request, body: nil, baseURL: URL(string: "https://api.example.com")!, operationID: "test") { req, body, url in
      #expect(req.headerFields[.authorization] == nil)
      return (HTTPResponse(status: .ok), nil)
    }
  }

  @Test
  func addsNoHeaderWhenTokenIsEmpty() async throws {
    let middleware = BearerTokenMiddleware(token: "")
    let request = HTTPRequest(method: .get, scheme: "https", authority: "api.example.com", path: "/v1/chat")

    _ = try await middleware.intercept(request, body: nil, baseURL: URL(string: "https://api.example.com")!, operationID: "test") { req, body, url in
      #expect(req.headerFields[.authorization] == nil)
      return (HTTPResponse(status: .ok), nil)
    }
  }

  @Test
  func preservesExistingHeaders() async throws {
    let middleware = BearerTokenMiddleware(token: "sk-abc123")
    var request = HTTPRequest(method: .post, scheme: "https", authority: "api.example.com", path: "/v1/chat")
    request.headerFields[.contentType] = "application/json"

    _ = try await middleware.intercept(request, body: nil, baseURL: URL(string: "https://api.example.com")!, operationID: "test") { req, body, url in
      #expect(req.headerFields[.authorization] == "Bearer sk-abc123")
      #expect(req.headerFields[.contentType] == "application/json")
      return (HTTPResponse(status: .ok), nil)
    }
  }
}
