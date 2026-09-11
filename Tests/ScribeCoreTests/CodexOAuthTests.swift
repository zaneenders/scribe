import Foundation
import ScribeCore
import Testing

@testable import ScribeCodexAuth

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
    #if canImport(Glibc) || canImport(Musl)
    let socketFD = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
    #else
    let socketFD = socket(AF_INET, SOCK_STREAM, 0)
    #endif
    try #require(socketFD >= 0)
    defer { close(socketFD) }

    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    // Reserve an OS-assigned port, not the production OAuth port.
    address.sin_port = 0
    address.sin_addr.s_addr = inet_addr(CodexOAuthConstants.callbackHost)

    let bindResult = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    try #require(bindResult == 0, "Could not reserve OAuth callback port: errno \(errno)")
    try #require(listen(socketFD, 1) == 0)

    // Keep the reservation open throughout login: releasing it before login
    // would introduce a race with other processes claiming the same port.
    var addressLength = socklen_t(MemoryLayout<sockaddr_in>.size)
    let nameResult = withUnsafeMutablePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        getsockname(socketFD, $0, &addressLength)
      }
    }
    try #require(nameResult == 0, "Could not read reserved port: errno \(errno)")
    let reservedPort = UInt16(bigEndian: address.sin_port)
    try #require(reservedPort != 0)

    let start = ContinuousClock.now
    do {
      _ = try await CodexOAuth.login(
        callbackHost: CodexOAuthConstants.callbackHost,
        callbackPort: reservedPort,
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
    // No callback is sent, so an OS-assigned port is sufficient. This avoids
    // collisions with real OAuth logins or other test processes on port 1455.
    let start = ContinuousClock.now
    do {
      _ = try await CodexOAuth.login(
        callbackHost: CodexOAuthConstants.callbackHost,
        callbackPort: 0,
        browserOpener: { _ in
          // Intentionally left hanging.
        },
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
