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
  @Test(arguments: ["http://example.com", "http://127.0.0.1", "https://user:secret@example.com", "https://example.com/?token=secret", "https://example.com/path", "https://example.com/#secret", "file:///tmp/server"])
  func rejectsUnsafeOrigins(origin: String) {
    #expect(throws: CodexAuthorityError.self) { _ = try CodexServerTransport.origin(origin) }
  }
  @Test func tunnelIsExplicitAndLoopbackOnly() throws {
    #expect(try CodexServerTransport.origin("http://127.0.0.1:8080", sshTunnel: true) == "http://127.0.0.1:8080")
    #expect(throws: CodexAuthorityError.self) { _ = try CodexServerTransport.origin("http://remote.example", sshTunnel: true) }
    #expect(try CodexServerTransport.origin("https://TRUSTED.example:443/") == "https://trusted.example")
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
    let request = CodexHandoffRequest(handoffID: UUID(), expectedGeneration: 0, credential: credential)
    let error = CodexOAuthError.tokenExchangeFailed(status: 400, body: "refresh-secret")
    for text in [String(describing: credential), String(reflecting: credential), String(reflecting: CodexAccessCredential(credential)),
      String(describing: request), String(reflecting: request), error.localizedDescription, String(reflecting: error), String(describing: error)] {
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
    child.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    child.arguments = ["-c", "import fcntl,sys; f=open(sys.argv[1], 'r+');\ntry: fcntl.flock(f, fcntl.LOCK_EX|fcntl.LOCK_NB); sys.exit(1)\nexcept BlockingIOError: sys.exit(0)", directory.appendingPathComponent("codex-authority.lock").path]
    try child.run(); child.waitUntilExit()
    #expect(child.terminationStatus == 0)
  }

  @Test func brokerRejectsRedirectWithoutDeliveringSecrets() async throws {
    let listener = socket(AF_INET, SOCK_STREAM, 0)
    #expect(listener >= 0)
    defer { close(listener) }
    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    let bound = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    #expect(bound == 0); #expect(listen(listener, 2) == 0)
    var size = socklen_t(MemoryLayout<sockaddr_in>.size)
    _ = withUnsafeMutablePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(listener, $0, &size) }
    }
    let port = UInt16(bigEndian: address.sin_port)
    let done = Task.detached {
      var pollDescriptor = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
      guard poll(&pollDescriptor, 1, 5_000) == 1 else { Issue.record("No request"); return }
      let client = accept(listener, nil, nil)
      guard client >= 0 else { Issue.record("No accepted socket"); return }
      defer { close(client) }
      var buffer = [UInt8](repeating: 0, count: 16_384)
      _ = recv(client, &buffer, buffer.count, 0)
      let response = "HTTP/1.1 307 Temporary Redirect\r\nLocation: http://127.0.0.1:\(port)/stolen\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
      _ = response.withCString { send(client, $0, strlen($0), 0) }
      #expect(poll(&pollDescriptor, 1, 500) == 0)
    }
    let client = try CodexBrokerClient(origin: "http://127.0.0.1:\(port)", sshTunnel: true, bearer: { "fake-device-token" })
    await #expect(throws: CodexAuthorityError.self) { _ = try await client.status() }
    await done.value
  }
}
