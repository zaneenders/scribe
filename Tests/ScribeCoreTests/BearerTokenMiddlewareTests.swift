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
        let request = try await interceptedRequest(
            through: BearerTokenMiddleware(token: "secret-token")
        )

        let auth = try #require(request.headerFields[.authorization])
        #expect(auth == "Bearer secret-token")
    }

    @Test("omits Authorization for absent tokens", arguments: [Optional<String>.none, ""])
    func omitsAuthorization(token: String?) async throws {
        let request = try await interceptedRequest(
            through: BearerTokenMiddleware(token: token)
        )

        #expect(request.headerFields[.authorization] == nil)
    }

    @Test("preserves existing request headers")
    func preservesExistingHeaders() async throws {
        var req = HTTPRequest(method: .post, scheme: "https", authority: "api.example.com", path: "/v1/chat")
        req.headerFields[.contentType] = "application/json"

        let captured = try await interceptedRequest(
            through: BearerTokenMiddleware(token: "token"),
            request: req
        )

        #expect(captured.headerFields[.contentType] == "application/json")
        #expect(captured.headerFields[.authorization] == "Bearer token")
    }

    // MARK: - Response pass-through

    @Test("passes through response unchanged")
    func passesThroughResponse() async throws {
        let middleware = BearerTokenMiddleware(token: "token")
        let request = HTTPRequest(method: .get, scheme: "https", authority: "api.example.com", path: "/")
        let baseURL = URL(string: "https://api.example.com")!

        let expectedResponse = HTTPResponse(status: .init(code: 201))
        let (response, _) = try await middleware.intercept(
            request, body: nil, baseURL: baseURL, operationID: "test"
        ) { _, _, _ in
            (expectedResponse, nil)
        }

        #expect(response.status.code == 201)
    }
}
