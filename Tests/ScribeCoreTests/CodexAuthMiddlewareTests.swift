import Foundation
import HTTPTypes
import OpenAPIRuntime
import ScribeCodexAuth
import Testing

@testable import ScribeLLMResponses

@Suite
struct CodexAuthMiddlewareTests {

  @Test("a rejected OAuth token is refreshed once and the JSON request is replayed")
  func refreshesRejectedToken() async throws {
    let transport = ScriptedTransport(responses: [
      .init(status: 401, chunks: [Array(#"{"error":{"code":"token_invalidated"}}"#.utf8)[...]]),
      .init(status: 200, chunks: sseChunks(#"{"type":"response.completed"}"#)),
    ])
    let credentials = CredentialSource()
    let client = Client(
      serverURL: URL(string: "https://codex.example.com")!, transport: transport,
      middlewares: [CodexAuthMiddleware { try await credentials.load(rejecting: $0) }])

    _ = try await client.createResponse(body: .json(.init(model: "test-model")))

    let requests = transport.capturedRequests
    #expect(requests.count == 2)
    #expect(requests.allSatisfy { $0.path == "/codex/responses" })
    #expect(requests[0].headers[.authorization] == "Bearer original")
    #expect(requests[1].headers[.authorization] == "Bearer refreshed")
    #expect(requests[1].headers[.init("chatgpt-account-id")!] == "refreshed-account")
    #expect(requests[0].body == requests[1].body)
    #expect(requests[0].body != nil)
    #expect(await credentials.rejections == [nil, "original"])
  }

  @Test("a second 401 requires browser sign-in without further retries")
  func stopsAfterSecondUnauthorizedResponse() async throws {
    let transport = ScriptedTransport(status: 401)
    let credentials = CredentialSource()
    let client = Client(
      serverURL: URL(string: "https://codex.example.com")!, transport: transport,
      middlewares: [CodexAuthMiddleware { try await credentials.load(rejecting: $0) }])
    do {
      _ = try await client.createResponse(body: .json(.init(model: "test-model")))
      Issue.record("Expected sign-in to be required")
    } catch let error as ClientError {
      let authError = try #require(error.underlyingError as? CodexOAuthError)
      guard case .loginRequired = authError else {
        Issue.record("Unexpected auth error: \(authError)")
        return
      }
      #expect(authError.localizedDescription.contains("Sign in to Codex"))
    }
    #expect(transport.capturedRequests.count == 2)
  }

  @Test("each request reloads credentials so existing clients see browser sign-in")
  func reloadsCredentialsBetweenRequests() async throws {
    let transport = ScriptedTransport(
      status: 200, chunks: sseChunks(#"{"type":"response.completed"}"#))
    let credentials = CredentialSource()
    let client = Client(
      serverURL: URL(string: "https://codex.example.com")!, transport: transport,
      middlewares: [CodexAuthMiddleware { try await credentials.load(rejecting: $0) }])
    _ = try await client.createResponse(body: .json(.init(model: "test-model")))
    await credentials.replaceAccess("browser-login")
    _ = try await client.createResponse(body: .json(.init(model: "test-model")))
    #expect(transport.capturedRequests.map { $0.headers[.authorization] } == [
      "Bearer original", "Bearer browser-login",
    ])
    #expect(await credentials.rejections == [nil, nil])
  }

  @Test("non-authentication failures do not refresh credentials")
  func doesNotRefreshOtherFailures() async throws {
    let transport = ScriptedTransport(status: 429)
    let credentials = CredentialSource()
    let client = Client(
      serverURL: URL(string: "https://codex.example.com")!, transport: transport,
      middlewares: [CodexAuthMiddleware { try await credentials.load(rejecting: $0) }])
    let response = try await client.createResponse(body: .json(.init(model: "test-model")))
    guard case .undocumented(statusCode: 429, _) = response else {
      Issue.record("Expected the original HTTP 429")
      return
    }
    #expect(transport.capturedRequests.count == 1)
    #expect(await credentials.rejections == [nil])
  }

  @Test("injects Authorization and account-id when both provided")
  func injectsBothHeaders() async throws {
    let request = try await interceptedRequest(
      through: CodexAuthMiddleware(token: "tok", accountID: "acct-123")
    )

    #expect(request.headerFields[.authorization] == "Bearer tok")
    #expect(request.headerFields[.init("chatgpt-account-id")!] == "acct-123")
    #expect(request.headerFields[.init("originator")!] == "pi")
  }

  @Test("injects only Authorization when accountID is nil")
  func injectsOnlyAuthorizationWhenAccountIDNil() async throws {
    let request = try await interceptedRequest(
      through: CodexAuthMiddleware(token: "tok", accountID: nil)
    )

    #expect(request.headerFields[.authorization] == "Bearer tok")
    #expect(request.headerFields[.init("chatgpt-account-id")!] == nil)
    #expect(request.headerFields[.init("originator")!] == "pi")
  }

  @Test("does not inject Authorization for absent tokens", arguments: [Optional<String>.none, ""])
  func noAuthWhenTokenNilOrEmpty(token: String?) async throws {
    let request = try await interceptedRequest(
      through: CodexAuthMiddleware(token: token, accountID: "acct-123")
    )

    #expect(request.headerFields[.authorization] == nil)
    #expect(request.headerFields[.init("chatgpt-account-id")!] == "acct-123")
  }

  @Test("does not inject account-id for absent values", arguments: [Optional<String>.none, ""])
  func noAccountIDWhenNilOrEmpty(accountID: String?) async throws {
    let request = try await interceptedRequest(
      through: CodexAuthMiddleware(token: "tok", accountID: accountID)
    )

    #expect(request.headerFields[.init("chatgpt-account-id")!] == nil)
  }

  @Test("always sets originator header to pi")
  func setsOriginatorHeader() async throws {
    let request = try await interceptedRequest(
      through: CodexAuthMiddleware(token: nil, accountID: nil)
    )

    #expect(request.headerFields[.init("originator")!] == "pi")
  }

  @Test("does not overwrite existing originator header")
  func preservesExistingOriginator() async throws {
    var req = HTTPRequest(method: .get, scheme: "https", authority: "api.example.com", path: "/")
    req.headerFields[.init("originator")!] = "custom"

    let captured = try await interceptedRequest(
      through: CodexAuthMiddleware(token: nil, accountID: nil),
      request: req
    )

    #expect(captured.headerFields[.init("originator")!] == "custom")
  }

  @Test("passes through response unchanged")
  func passesThroughResponse() async throws {
    let middleware = CodexAuthMiddleware(token: "tok", accountID: "acct")
    let request = HTTPRequest(method: .get, scheme: "https", authority: "api.example.com", path: "/")
    let baseURL = URL(string: "https://api.example.com")!

    let expectedResponse = HTTPResponse(status: .init(code: 403))
    let (response, _) = try await middleware.intercept(
      request, body: nil, baseURL: baseURL, operationID: "test"
    ) { _, _, _ in
      (expectedResponse, nil)
    }

    #expect(response.status.code == 403)
  }
}

private actor CredentialSource {
  private var access = "original"
  private(set) var rejections: [String?] = []

  func replaceAccess(_ access: String) { self.access = access }

  func load(rejecting: String?) throws -> CodexCredential {
    rejections.append(rejecting)
    if rejecting != nil { access = "refreshed" }
    return CodexCredential(
      access: access, refresh: "refresh", expires: 9_999_999_999_999,
      accountId: access == "refreshed" ? "refreshed-account" : "account")
  }
}
