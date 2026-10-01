import Foundation
import HTTPTypes
import OpenAPIRuntime
import Testing
@testable import ScribeCodexAuth
@testable import ScribeLLMResponses
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

struct CodexAuthoritySecurityTests {
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
      throw CodexAuthorityError.unavailable
    }
    await #expect(throws: CodexAuthorityError.self) {
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

  @Test func storeLockCoordinatesASeparateProcess() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let lock = try CodexStoreLock(directory: directory)
    defer { withExtendedLifetime(lock) {} }
    // exec avoids inheriting Swift runtime state into the child.
    let child = Process()
    child.executableURL = URL(fileURLWithPath: "/usr/bin/flock")
    child.arguments = ["-n", directory.appendingPathComponent("codex-authority.lock").path, "true"]
    try child.run(); child.waitUntilExit()
    #expect(child.terminationStatus == 1)
  }


}
