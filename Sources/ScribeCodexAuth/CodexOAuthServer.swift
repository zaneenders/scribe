import Foundation
import Synchronization

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

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

enum CodexOAuthCallbackServer {

  static let loginTimeout: TimeInterval = 300

  private final class ListeningSocket: Sendable {
    private struct State: ~Copyable {
      var descriptor: Int32?
      var cancelled = false
    }

    private let state = Mutex(State())

    func install(_ descriptor: Int32) -> Bool {
      state.withLock { state in
        guard !state.cancelled else { return false }
        precondition(state.descriptor == nil, "Listening socket installed more than once")
        state.descriptor = descriptor
        return true
      }
    }

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
        group.addTask {
          try await Task.sleep(for: .seconds(timeout))
          throw CodexOAuthError.loginTimeout
        }

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
            box.closeIfOpen()
          }
        }

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
      box.closeIfOpen()
    }
  }

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

    #if canImport(Glibc) || canImport(Musl)
    let sock = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
    #else
    let sock = socket(AF_INET, SOCK_STREAM, 0)
    #endif
    guard sock >= 0 else {
      failStartup(.serverError("socket() failed: \(errno)"))
      return
    }
    guard box.install(sock) else {
      close(sock)
      failStartup(.loginCancelled)
      return
    }
    defer { box.closeIfOpen() }

    var reuse: Int32 = 1
    setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

    var tv = timeval(tv_sec: 2, tv_usec: 0)
    setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

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

    guard listen(sock, 1) >= 0 else {
      failStartup(.serverError("listen() failed: \(errno)"))
      return
    }

    onReady?(.success(()))

    while true {
      let client = accept(sock, nil, nil)
      if client < 0 {
        switch errno {
        case EBADF, EINVAL:
          continuation.resume(throwing: CodexOAuthError.loginCancelled)
          return
        case EAGAIN, EWOULDBLOCK, EINTR:
          continue
        default:
          continuation.resume(
            throwing: CodexOAuthError.serverError("accept() failed: \(errno)"))
          return
        }
      }

      if let code = handleConnection(client, expectedState: expectedState) {
        close(client)
        continuation.resume(returning: code)
        return
      }

      close(client)
    }
  }

  private static func handleConnection(
    _ client: Int32,
    expectedState: String
  ) -> String? {
    var requestBuffer = [UInt8](repeating: 0, count: 4096)
    let bytesRead = read(client, &requestBuffer, requestBuffer.count)
    guard bytesRead > 0 else { return nil }

    let request = String(decoding: requestBuffer[0..<bytesRead], as: UTF8.self)

    guard let firstLine = request.split(separator: "\r\n").first.map(String.init) else {
      sendResponse(client, status: 400, body: htmlPage(title: "Error", body: "Bad request"))
      return nil
    }

    let parts = firstLine.split(separator: " ")
    guard parts.count >= 2, let path = parts.dropFirst().first.map(String.init) else {
      sendResponse(client, status: 400, body: htmlPage(title: "Error", body: "Bad request"))
      return nil
    }

    guard
      let urlComponents = URLComponents(string: path),
      urlComponents.path == "/auth/callback"
    else {
      sendResponse(
        client, status: 404,
        body: htmlPage(title: "Not Found", body: "Callback route not found."))
      return nil
    }

    let params =
      urlComponents.queryItems?.reduce(into: [String: String]()) { dict, item in
        dict[item.name] = item.value
      } ?? [:]

    guard params["state"] == expectedState else {
      sendResponse(
        client, status: 400,
        body: htmlPage(title: "Error", body: "State mismatch."))
      return nil
    }

    guard let code = params["code"], !code.isEmpty else {
      sendResponse(
        client, status: 400,
        body: htmlPage(title: "Error", body: "Missing authorization code."))
      return nil
    }

    sendResponse(
      client, status: 200,
      body: htmlPage(
        title: "Authenticated",
        body: "OpenAI authentication completed. You can close this window."))
    return code
  }

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
