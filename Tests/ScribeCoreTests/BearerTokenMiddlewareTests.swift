import Foundation
import HTTPTypes
import OpenAPIRuntime
import Testing

@testable import ScribeLLM

@Suite
struct BearerTokenMiddlewareTests {

  // MARK: - Token injection

  @Test("injects Authorization header when token is provided")
  func injectsAuthorizationWhenTokenProvided() async throws {
    let middleware = BearerTokenMiddleware(token: "secret-token")
    let request = HTTPRequest(method: .get, scheme: "https", authority: "api.example.com", path: "/v1/chat")
    let baseURL = URL(string: "https://api.example.com")!

    var capturedRequest: HTTPRequest?
    let _ = try await middleware.intercept(request, body: nil, baseURL: baseURL, operationID: "test") {
      req, body, url in
      capturedRequest = req
      return (HTTPResponse(status: .ok), nil)
    }

    let auth = try #require(capturedRequest?.headerFields[.authorization])
    #expect(auth == "Bearer secret-token")
  }

  @Test("does not inject Authorization when token is nil")
  func noInjectionWhenTokenNil() async throws {
    let middleware = BearerTokenMiddleware(token: nil)
    let request = HTTPRequest(method: .get, scheme: "https", authority: "api.example.com", path: "/v1/chat")
    let baseURL = URL(string: "https://api.example.com")!

    var capturedRequest: HTTPRequest?
    let _ = try await middleware.intercept(request, body: nil, baseURL: baseURL, operationID: "test") {
      req, body, url in
      capturedRequest = req
      return (HTTPResponse(status: .ok), nil)
    }

    #expect(capturedRequest?.headerFields[.authorization] == nil)
  }

  @Test("does not inject Authorization when token is empty string")
  func noInjectionWhenTokenEmpty() async throws {
    let middleware = BearerTokenMiddleware(token: "")
    let request = HTTPRequest(method: .get, scheme: "https", authority: "api.example.com", path: "/v1/chat")
    let baseURL = URL(string: "https://api.example.com")!

    var capturedRequest: HTTPRequest?
    let _ = try await middleware.intercept(request, body: nil, baseURL: baseURL, operationID: "test") {
      req, body, url in
      capturedRequest = req
      return (HTTPResponse(status: .ok), nil)
    }

    #expect(capturedRequest?.headerFields[.authorization] == nil)
  }

  @Test("preserves existing request headers")
  func preservesExistingHeaders() async throws {
    let middleware = BearerTokenMiddleware(token: "token")
    var request = HTTPRequest(method: .post, scheme: "https", authority: "api.example.com", path: "/v1/chat")
    request.headerFields[.contentType] = "application/json"
    let baseURL = URL(string: "https://api.example.com")!

    var capturedRequest: HTTPRequest?
    let _ = try await middleware.intercept(request, body: nil, baseURL: baseURL, operationID: "test") {
      req, body, url in
      capturedRequest = req
      return (HTTPResponse(status: .ok), nil)
    }

    #expect(capturedRequest?.headerFields[.contentType] == "application/json")
    #expect(capturedRequest?.headerFields[.authorization] == "Bearer token")
  }

  @Test("passes through response unchanged")
  func passesThroughResponse() async throws {
    let middleware = BearerTokenMiddleware(token: "token")
    let request = HTTPRequest(method: .get, scheme: "https", authority: "api.example.com", path: "/")
    let baseURL = URL(string: "https://api.example.com")!

    let expectedResponse = HTTPResponse(status: .init(code: 201))
    let (response, _) = try await middleware.intercept(request, body: nil, baseURL: baseURL, operationID: "test") {
      _, _, _ in
      return (expectedResponse, nil)
    }

    #expect(response.status.code == 201)
  }
}
