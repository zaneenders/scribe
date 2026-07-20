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

    // MARK: - Originator header

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

    // MARK: - Response pass-through

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
