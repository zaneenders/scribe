import Foundation
import HTTPTypes
import OpenAPIRuntime
import Testing

@testable import ScribeLLM

@Suite
struct KimiCodeRequestMiddlewareTests {

    // MARK: - Host gating: kimi.com

    @Test("injects headers when baseURL is kimi.com")
    func injectsHeadersForKimiCom() async throws {
        let headers = ["X-Custom": "value1", "X-Another": "value2"]
        var request = HTTPRequest(method: .get, scheme: "https", authority: "kimi.com", path: "/coding/chat")
        request.headerFields[.contentType] = "application/json"

        let captured = try await interceptedRequest(
            through: KimiCodeRequestMiddleware(headers: headers),
            request: request,
            baseURL: URL(string: "https://kimi.com")!
        )

        #expect(captured.headerFields[.init("X-Custom")!] == "value1")
        #expect(captured.headerFields[.init("X-Another")!] == "value2")
        #expect(captured.headerFields[.contentType] == "application/json")
    }

    @Test("injects headers when baseURL is subdomain of kimi.com")
    func injectsHeadersForKimiSubdomain() async throws {
        let headers = ["X-Custom": "val"]

        let captured = try await interceptedRequest(
            through: KimiCodeRequestMiddleware(headers: headers),
            request: HTTPRequest(method: .get, scheme: "https", authority: "api.kimi.com", path: "/v1/chat"),
            baseURL: URL(string: "https://api.kimi.com")!
        )

        #expect(captured.headerFields[.init("X-Custom")!] == "val")
    }

    // MARK: - Host gating: non-kimi hosts

    @Test("does not inject headers for non-kimi host")
    func skipsInjectionForOtherHost() async throws {
        let headers = ["X-Custom": "should-not-appear"]

        let captured = try await interceptedRequest(
            through: KimiCodeRequestMiddleware(headers: headers),
            request: HTTPRequest(method: .get, scheme: "https", authority: "api.openai.com", path: "/v1/chat"),
            baseURL: URL(string: "https://api.openai.com")!
        )

        #expect(captured.headerFields[.init("X-Custom")!] == nil)
    }

    @Test("does not inject headers for host containing kimi.com as substring")
    func skipsInjectionForKimiComSubstring() async throws {
        let headers = ["X-Custom": "should-not-appear"]

        let captured = try await interceptedRequest(
            through: KimiCodeRequestMiddleware(headers: headers),
            request: HTTPRequest(method: .get, scheme: "https", authority: "notkimi.com", path: "/v1/chat"),
            baseURL: URL(string: "https://notkimi.com")!
        )

        #expect(captured.headerFields[.init("X-Custom")!] == nil)
    }

    @Test("handles empty headers dictionary")
    func handlesEmptyHeaders() async throws {
        var request = HTTPRequest(method: .get, scheme: "https", authority: "kimi.com", path: "/")
        request.headerFields[.contentType] = "application/json"

        let captured = try await interceptedRequest(
            through: KimiCodeRequestMiddleware(headers: [:]),
            request: request,
            baseURL: URL(string: "https://kimi.com")!
        )

        // Should not crash and should preserve existing headers
        #expect(captured.headerFields[.contentType] == "application/json")
    }

    @Test("passes through response unchanged")
    func passesThroughResponse() async throws {
        let middleware = KimiCodeRequestMiddleware(headers: ["X-A": "b"])
        let request = HTTPRequest(method: .get, scheme: "https", authority: "kimi.com", path: "/")
        let baseURL = URL(string: "https://kimi.com")!

        let expectedResponse = HTTPResponse(status: .init(code: 202))
        let (response, _) = try await middleware.intercept(
            request, body: nil, baseURL: baseURL, operationID: "test"
        ) { _, _, _ in
            (expectedResponse, nil)
        }

        #expect(response.status.code == 202)
    }

    @Test("preserves existing request method and path")
    func preservesMethodAndPath() async throws {
        let captured = try await interceptedRequest(
            through: KimiCodeRequestMiddleware(headers: ["X-K": "v"]),
            request: HTTPRequest(method: .post, scheme: "https", authority: "kimi.com", path: "/coding/stream"),
            baseURL: URL(string: "https://kimi.com")!
        )

        #expect(captured.method == .post)
        #expect(captured.path == "/coding/stream")
    }
}
