import Foundation
import HTTPTypes
import OpenAPIRuntime
import Testing
@testable import ScribeCodexAuth
@testable import ScribeLLMResponses
struct CodexAccessProviderTests {
  @Test func accessCredentialContainsOnlyAccessFields() throws {
    let credential = CodexAccessCredential(access: "access", accountId: "account", expires: 123)
    let data = try JSONEncoder().encode(credential)
    let fields = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(Set(fields.keys) == ["access", "accountId", "expires"])
    #expect(try JSONDecoder().decode(CodexAccessCredential.self, from: data) == credential)
  }

  @Test func providerRejectsArbitraryBackendBeforeLoadingCredentials() async throws {
    let middleware = CodexAuthMiddleware { _ in
      Issue.record("Must not load secret for arbitrary origin")
      throw CodexOAuthError.noCredentials
    }
    await #expect(throws: URLError.self) {
      _ = try await middleware.intercept(HTTPRequest(method: .post, scheme: nil, authority: nil, path: "/responses"), body: nil,
        baseURL: URL(string: "https://evil.example")!, operationID: "test") { _, _, _ in
          Issue.record("Must not send request"); return (HTTPResponse(status: .ok), nil)
        }
    }
  }

  @Test func credentialDescriptionsAndErrorsAreRedacted() {
    let credential = CodexCredential(access: "access-secret", refresh: "refresh-secret", expires: 123, accountId: "account")
    let error = CodexOAuthError.tokenExchangeFailed(status: 400, body: "refresh-secret")
    for text in [String(describing: credential), String(reflecting: credential), String(reflecting: CodexAccessCredential(credential)),
      error.localizedDescription, String(reflecting: error), String(describing: error)] {
      #expect(!text.contains("refresh-secret")); #expect(!text.contains("access-secret"))
    }
  }

}
