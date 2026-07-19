import Foundation
import Testing

@testable import ScribeCodexAuth
import ScribeCore

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

@Suite(.serialized)
struct CodexOAuthTests {
  @Test("login fails promptly when the callback port is occupied", .timeLimit(.minutes(1)))
  func occupiedCallbackPortFailsPromptly() async throws {
    let socketFD = socket(AF_INET, SOCK_STREAM, 0)
    try #require(socketFD >= 0)
    defer { close(socketFD) }

    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = CodexOAuthConstants.callbackPort.bigEndian
    address.sin_addr.s_addr = inet_addr(CodexOAuthConstants.callbackHost)

    let bindResult = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    try #require(bindResult == 0, "Could not reserve OAuth callback port: errno \(errno)")
    try #require(listen(socketFD, 1) == 0)

    let start = ContinuousClock.now
    do {
      _ = try await CodexOAuth.login(
        callbackHost: CodexOAuthConstants.callbackHost,
        callbackPort: CodexOAuthConstants.callbackPort,
        browserOpener: { _ in Issue.record("Browser opened before callback server was ready") }
      )
      Issue.record("Expected login to fail when the callback port is occupied")
    } catch let error as CodexOAuthError {
      guard case .serverError(let message) = error else {
        Issue.record("Expected serverError, got \(error)")
        return
      }
      #expect(message.contains("bind() failed"))
    }

    #expect(start.duration(to: .now) < .seconds(2))
  }

  @Test("waitForCode returns loginTimeout after the configured timeout", .timeLimit(.minutes(1)))
  func loginTimeoutWithShortDeadline() async throws {
    // Use a very short timeout and never send a callback request.
    let start = ContinuousClock.now
    do {
      _ = try await CodexOAuth.login(
        callbackHost: CodexOAuthConstants.callbackHost,
        callbackPort: CodexOAuthConstants.callbackPort,
        browserOpener: { _ in /* intentionally left hanging */ },
        timeout: 2.0
      )
      Issue.record("Expected loginTimeout, but login succeeded unexpectedly")
    } catch let error as CodexOAuthError {
      guard case .loginTimeout = error else {
        Issue.record("Expected loginTimeout, got \(error)")
        return
      }
      // Confirm the error arrived close to the configured deadline.
      let elapsed = start.duration(to: .now)
      #expect(elapsed >= .seconds(2))
      #expect(elapsed < .seconds(8))  // generous upper bound to avoid flakes
    }
  }
}
