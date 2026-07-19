import Foundation
import Synchronization

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

// MARK: - OAuth Constants

public enum CodexOAuthConstants {
  public static let clientId = "app_EMoamEEZ73f0CkXaXp7hrann"
  public static let authBaseURL = "https://auth.openai.com"
  public static let authorizeURL = "\(authBaseURL)/oauth/authorize"
  public static let tokenURL = "\(authBaseURL)/oauth/token"
  public static let redirectURI = "http://localhost:1455/auth/callback"
  public static let scope = "openid profile email offline_access"
  public static let jwtClaimPath = "https://api.openai.com/auth"
  public static let callbackPort: UInt16 = 1455
  public static let callbackHost = "127.0.0.1"
}

// MARK: - Callback Server

/// Minimal HTTP server for the OAuth callback.
/// Uses a raw POSIX socket — no NIO dependency needed for this simple task.
///
/// The server keeps accepting connections until a valid OAuth callback arrives
/// or the overall timeout expires.  Invalid or unrelated requests are answered
/// with an appropriate HTTP error and the server continues listening.
enum CodexOAuthCallbackServer {

  /// Overall timeout for the login flow (seconds).
  static let loginTimeout: TimeInterval = 300 // 5 minutes

  /// Thread-safe ownership of the listening socket.
  ///
  /// Cancellation may arrive before or after the server creates its socket.
  /// `install` transfers ownership into this state unless cancellation already
  /// won; `closeIfOpen` atomically takes ownership before closing so the file
  /// descriptor is closed exactly once.
  private final class ListeningSocket: Sendable {
    private struct State: ~Copyable {
      var descriptor: Int32?
      var cancelled = false
    }

    private let state = Mutex(State())

    /// Install a newly created descriptor, returning false if cancellation won.
    func install(_ descriptor: Int32) -> Bool {
      state.withLock { state in
        guard !state.cancelled else { return false }
        precondition(state.descriptor == nil, "Listening socket installed more than once")
        state.descriptor = descriptor
        return true
      }
    }

    /// Close the descriptor once and prevent any later descriptor installation.
    func closeIfOpen() {
      let descriptor = state.withLock { state -> Int32? in
        state.cancelled = true
        defer { state.descriptor = nil }
        return state.descriptor
      }
      if let descriptor {
        close(descriptor)
      }
    }
  }

  /// Start the callback server and wait for a valid authorization code.
  /// - Parameters:
  ///   - expectedState: CSRF state token to verify in the callback.
  ///   - host: Bind address (default 127.0.0.1).
  ///   - port: Bind port (default 1455).
  ///   - timeout: Maximum time to wait (default 5 minutes).
  ///   - onReady: Called with success after bind+listen, or with the startup
  ///     error if the server cannot begin listening.
  /// - Returns: The authorization code.
  static func waitForCode(
    expectedState: String,
    host: String = CodexOAuthConstants.callbackHost,
    port: UInt16 = CodexOAuthConstants.callbackPort,
    timeout: TimeInterval = loginTimeout,
    onReady: (@Sendable (Result<Void, Error>) -> Void)? = nil
  ) async throws -> String {
    let box = ListeningSocket()

    return try await withTaskCancellationHandler {
      try await withThrowingTaskGroup(of: String.self) { group in
        // Timeout task — fires after `timeout` seconds.
        group.addTask {
          try await Task.sleep(for: .seconds(timeout))
          throw CodexOAuthError.loginTimeout
        }

        // Server task — blocks until a valid callback is received.
        group.addTask {
          try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
              Thread {
                runServer(
                  host: host,
                  port: port,
                  expectedState: expectedState,
                  continuation: continuation,
                  onReady: onReady,
                  box: box
                )
              }.start()
            }
          } onCancel: {
            // When the server task is cancelled (e.g. timeout wins),
            // close the socket so accept() unblocks with EBADF and
            // the continuation is resumed rather than left dangling.
            box.closeIfOpen()
          }
        }

        // Take the first completed child.
        // Wrap in do/catch so cancelAll runs on every exit path.
        let code: String
        do {
          code = try await group.next()!
        } catch {
          group.cancelAll()
          throw error
        }
        group.cancelAll()
        return code
      }
    } onCancel: {
      // Close the listening socket so accept() unblocks (returns EBADF).
      box.closeIfOpen()
    }
  }

  // MARK: - Synchronous Server (runs on a dedicated Thread)

  private static func runServer(
    host: String,
    port: UInt16,
    expectedState: String,
    continuation: CheckedContinuation<String, Error>,
    onReady: (@Sendable (Result<Void, Error>) -> Void)?,
    box: ListeningSocket
  ) {
    func failStartup(_ error: CodexOAuthError) {
      onReady?(.failure(error))
      continuation.resume(throwing: error)
    }

    // --- Create socket ---
    let sock = socket(AF_INET, SOCK_STREAM, 0)
    guard sock >= 0 else {
      failStartup(.serverError("socket() failed: \(errno)"))
      return
    }
    // Transfer ownership to the cancellation state. If cancellation arrived
    // before socket creation, retain ownership here and close it immediately.
    guard box.install(sock) else {
      close(sock)
      failStartup(.loginCancelled)
      return
    }
    defer { box.closeIfOpen() }

    // --- SO_REUSEADDR ---
    var reuse: Int32 = 1
    setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

    // --- Per-accept timeout so we can notice cancellation ---
    var tv = timeval(tv_sec: 2, tv_usec: 0)
    setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

    // --- Bind ---
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = port.bigEndian
    addr.sin_addr.s_addr = inet_addr(host)
    let bindResult = withUnsafePointer(to: &addr) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    guard bindResult >= 0 else {
      failStartup(.serverError("bind() failed: \(errno)"))
      return
    }

    // --- Listen ---
    guard listen(sock, 1) >= 0 else {
      failStartup(.serverError("listen() failed: \(errno)"))
      return
    }

    // --- Signal readiness ---
    // The caller can now safely launch the browser.
    onReady?(.success(()))

    // --- Accept loop ---
    // Keep accepting connections until we get a valid OAuth callback.
    while true {
      let client = accept(sock, nil, nil)
      if client < 0 {
        switch errno {
        case EBADF, EINVAL:
          // Socket was closed (cancellation).
          continuation.resume(throwing: CodexOAuthError.loginCancelled)
          return
        case EAGAIN, EWOULDBLOCK, EINTR:
          // SO_RCVTIMEO fired or a signal interrupted — retry.
          continue
        default:
          continuation.resume(
            throwing: CodexOAuthError.serverError("accept() failed: \(errno)"))
          return
        }
      }

      // Try to extract a valid authorization code from this connection.
      if let code = handleConnection(client, expectedState: expectedState) {
        close(client)
        continuation.resume(returning: code)
        return
      }

      close(client)
      // Invalid request — loop and accept the next connection.
    }
  }

  // MARK: - Connection Handling

  /// Parse one HTTP connection.  Returns the authorization code on success,
  /// or `nil` after sending an appropriate error response so the caller
  /// can continue accepting.
  private static func handleConnection(
    _ client: Int32,
    expectedState: String
  ) -> String? {
    // Read the request.
    var requestBuffer = [UInt8](repeating: 0, count: 4096)
    let bytesRead = read(client, &requestBuffer, requestBuffer.count)
    guard bytesRead > 0 else { return nil }

    let request = String(decoding: requestBuffer[0..<bytesRead], as: UTF8.self)

    // Parse the request line.
    guard let firstLine = request.split(separator: "\r\n").first.map(String.init) else {
      sendResponse(client, status: 400, body: htmlPage(title: "Error", body: "Bad request"))
      return nil
    }

    // GET /auth/callback?code=...&state=... HTTP/1.1
    let parts = firstLine.split(separator: " ")
    guard parts.count >= 2, let path = parts.dropFirst().first.map(String.init) else {
      sendResponse(client, status: 400, body: htmlPage(title: "Error", body: "Bad request"))
      return nil
    }

    // Only the callback route is recognised.
    guard
      let urlComponents = URLComponents(string: path),
      urlComponents.path == "/auth/callback"
    else {
      sendResponse(client, status: 404,
                   body: htmlPage(title: "Not Found", body: "Callback route not found."))
      return nil
    }

    let params = urlComponents.queryItems?.reduce(into: [String: String]()) { dict, item in
      dict[item.name] = item.value
    } ?? [:]

    // Verify CSRF state.
    guard params["state"] == expectedState else {
      sendResponse(client, status: 400,
                   body: htmlPage(title: "Error", body: "State mismatch."))
      return nil
    }

    // Extract authorization code.
    guard let code = params["code"], !code.isEmpty else {
      sendResponse(client, status: 400,
                   body: htmlPage(title: "Error", body: "Missing authorization code."))
      return nil
    }

    // Success — send the landing page and return the code.
    sendResponse(client, status: 200,
                 body: htmlPage(title: "Authenticated",
                                body: "OpenAI authentication completed. You can close this window."))
    return code
  }

  // MARK: - HTTP Response Helpers

  private static func sendResponse(_ sock: Int32, status: Int, body: String) {
    let statusText: String = {
      switch status {
      case 200: return "OK"
      case 400: return "Bad Request"
      case 404: return "Not Found"
      default: return "Error"
      }
    }()
    let response = """
      HTTP/1.1 \(status) \(statusText)\r
      Content-Type: text/html; charset=utf-8\r
      Content-Length: \(body.utf8.count)\r
      Connection: close\r
      \r
      \(body)
      """
    _ = response.withCString {
      send(sock, $0, strlen($0), 0)
    }
  }

  private static func htmlPage(title: String, body: String) -> String {
    """
    <!DOCTYPE html>
    <html><head><meta charset="utf-8"><title>\(title)</title></head>
    <body><p>\(body)</p></body></html>
    """
  }
}

// MARK: - OAuth Errors

public enum CodexOAuthError: Error, CustomStringConvertible {
  case stateMismatch
  case missingAuthorizationCode
  case tokenExchangeFailed(status: Int, body: String)
  case missingToken(String)
  case invalidJWT
  case noAccountID
  case noCredentials
  case loginTimeout
  case loginCancelled
  case serverError(String)

  public var description: String {
    switch self {
    case .stateMismatch:
      return "OAuth state mismatch — possible CSRF attack."
    case .missingAuthorizationCode:
      return "No authorization code received in callback."
    case .tokenExchangeFailed(let status, let body):
      return "Token exchange failed (HTTP \(status)): \(body)"
    case .missingToken(let field):
      return "Token response missing required field: \(field)"
    case .invalidJWT:
      return "Failed to decode JWT access token."
    case .noAccountID:
      return "No chatgpt_account_id found in JWT payload."
    case .noCredentials:
      return "No stored Codex credentials. Run `scribe login` first."
    case .loginTimeout:
      return "Login timed out. Please try again."
    case .loginCancelled:
      return "Login was cancelled."
    case .serverError(let msg):
      return "Callback server error: \(msg)"
    }
  }
}
