import Foundation
import HTTPTypes
import OpenAPIRuntime
import Testing

@testable import ScribeLLMCodex

@Suite
struct CodexAuthMiddlewareTests {

  // MARK: - Token injection

  @Test("injects Authorization and account-id when both provided")
  func injectsBothHeaders() async throws {
    let middleware = CodexAuthMiddleware(token: "tok", accountID: "acct-123")
    let request = HTTPRequest(method: .get, scheme: "https", authority: "api.example.com", path: "/")
    let baseURL = URL(string: "https://api.example.com")!

    var capturedRequest: HTTPRequest?
    let _ = try await middleware.intercept(request, body: nil, baseURL: baseURL, operationID: "test") {
      req, body, url in
      capturedRequest = req
      return (HTTPResponse(status: .ok), nil)
    }

    #expect(capturedRequest?.headerFields[.authorization] == "Bearer tok")
    #expect(capturedRequest?.headerFields[.init("chatgpt-account-id")!] == "acct-123")
    #expect(capturedRequest?.headerFields[.init("originator")!] == "pi")
  }

  @Test("injects only Authorization when accountID is nil")
  func injectsOnlyAuthorizationWhenAccountIDNil() async throws {
    let middleware = CodexAuthMiddleware(token: "tok", accountID: nil)
    let request = HTTPRequest(method: .get, scheme: "https", authority: "api.example.com", path: "/")
    let baseURL = URL(string: "https://api.example.com")!

    var capturedRequest: HTTPRequest?
    let _ = try await middleware.intercept(request, body: nil, baseURL: baseURL, operationID: "test") {
      req, body, url in
      capturedRequest = req
      return (HTTPResponse(status: .ok), nil)
    }

    #expect(capturedRequest?.headerFields[.authorization] == "Bearer tok")
    #expect(capturedRequest?.headerFields[.init("chatgpt-account-id")!] == nil)
    #expect(capturedRequest?.headerFields[.init("originator")!] == "pi")
  }

  @Test("does not inject Authorization when token is nil")
  func noAuthWhenTokenNil() async throws {
    let middleware = CodexAuthMiddleware(token: nil, accountID: "acct-123")
    let request = HTTPRequest(method: .get, scheme: "https", authority: "api.example.com", path: "/")
    let baseURL = URL(string: "https://api.example.com")!

    var capturedRequest: HTTPRequest?
    let _ = try await middleware.intercept(request, body: nil, baseURL: baseURL, operationID: "test") {
      req, body, url in
      capturedRequest = req
      return (HTTPResponse(status: .ok), nil)
    }

    #expect(capturedRequest?.headerFields[.authorization] == nil)
    #expect(capturedRequest?.headerFields[.init("chatgpt-account-id")!] == "acct-123")
  }

  @Test("does not inject Authorization when token is empty string")
  func noAuthWhenTokenEmpty() async throws {
    let middleware = CodexAuthMiddleware(token: "", accountID: nil)
    let request = HTTPRequest(method: .get, scheme: "https", authority: "api.example.com", path: "/")
    let baseURL = URL(string: "https://api.example.com")!

    var capturedRequest: HTTPRequest?
    let _ = try await middleware.intercept(request, body: nil, baseURL: baseURL, operationID: "test") {
      req, body, url in
      capturedRequest = req
      return (HTTPResponse(status: .ok), nil)
    }

    #expect(capturedRequest?.headerFields[.authorization] == nil)
  }

  @Test("does not inject account-id when it is empty string")
  func noAccountIDWhenEmpty() async throws {
    let middleware = CodexAuthMiddleware(token: "tok", accountID: "")
    let request = HTTPRequest(method: .get, scheme: "https", authority: "api.example.com", path: "/")
    let baseURL = URL(string: "https://api.example.com")!

    var capturedRequest: HTTPRequest?
    let _ = try await middleware.intercept(request, body: nil, baseURL: baseURL, operationID: "test") {
      req, body, url in
      capturedRequest = req
      return (HTTPResponse(status: .ok), nil)
    }

    #expect(capturedRequest?.headerFields[.init("chatgpt-account-id")!] == nil)
  }

  // MARK: - Originator header

  @Test("always sets originator header to pi")
  func setsOriginatorHeader() async throws {
    let middleware = CodexAuthMiddleware(token: nil, accountID: nil)
    let request = HTTPRequest(method: .get, scheme: "https", authority: "api.example.com", path: "/")
    let baseURL = URL(string: "https://api.example.com")!

    var capturedRequest: HTTPRequest?
    let _ = try await middleware.intercept(request, body: nil, baseURL: baseURL, operationID: "test") {
      req, body, url in
      capturedRequest = req
      return (HTTPResponse(status: .ok), nil)
    }

    #expect(capturedRequest?.headerFields[.init("originator")!] == "pi")
  }

  @Test("does not overwrite existing originator header")
  func preservesExistingOriginator() async throws {
    let middleware = CodexAuthMiddleware(token: nil, accountID: nil)
    var request = HTTPRequest(method: .get, scheme: "https", authority: "api.example.com", path: "/")
    request.headerFields[.init("originator")!] = "custom"
    let baseURL = URL(string: "https://api.example.com")!

    var capturedRequest: HTTPRequest?
    let _ = try await middleware.intercept(request, body: nil, baseURL: baseURL, operationID: "test") {
      req, body, url in
      capturedRequest = req
      return (HTTPResponse(status: .ok), nil)
    }

    #expect(capturedRequest?.headerFields[.init("originator")!] == "custom")
  }

  // MARK: - Response pass-through

  @Test("passes through response unchanged")
  func passesThroughResponse() async throws {
    let middleware = CodexAuthMiddleware(token: "tok", accountID: "acct")
    let request = HTTPRequest(method: .get, scheme: "https", authority: "api.example.com", path: "/")
    let baseURL = URL(string: "https://api.example.com")!

    let expectedResponse = HTTPResponse(status: .init(code: 403))
    let (response, _) = try await middleware.intercept(request, body: nil, baseURL: baseURL, operationID: "test") {
      _, _, _ in
      return (expectedResponse, nil)
    }

    #expect(response.status.code == 403)
  }
}
