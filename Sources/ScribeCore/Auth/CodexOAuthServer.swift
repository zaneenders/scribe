import Foundation

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

/// Minimal single-shot HTTP server for the OAuth callback.
/// Uses a raw POSIX socket — no NIO dependency needed for this simple task.
enum CodexOAuthCallbackServer {

  static func waitForCode(
    expectedState: String,
    host: String = CodexOAuthConstants.callbackHost,
    port: UInt16 = CodexOAuthConstants.callbackPort
  ) async throws -> String {
    // The server runs synchronously on a background thread.
    // We use a continuation to bridge to async/await.
    try await withCheckedThrowingContinuation { continuation in
      Thread {
        runServer(
          host: host,
          port: port,
          expectedState: expectedState,
          continuation: continuation
        )
      }.start()
    }
  }

  // MARK: - Synchronous Server (runs on a dedicated Thread)

  private static func runServer(
    host: String,
    port: UInt16,
    expectedState: String,
    continuation: CheckedContinuation<String, Error>
  ) {
    // Create socket
    let sock = socket(AF_INET, SOCK_STREAM, 0)
    guard sock >= 0 else {
      continuation.resume(throwing: CodexOAuthError.serverError("socket() failed: \(errno)"))
      return
    }
    defer { close(sock) }

    // Set SO_REUSEADDR
    var reuse: Int32 = 1
    setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

    // Bind
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = port.bigEndian
    addr.sin_addr.s_addr = inet_addr(host)
    let bindResult = withUnsafePointer(to: &addr) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    guard bindResult >= 0 else {
      continuation.resume(throwing: CodexOAuthError.serverError("bind() failed: \(errno)"))
      return
    }

    // Listen
    guard listen(sock, 1) >= 0 else {
      continuation.resume(throwing: CodexOAuthError.serverError("listen() failed: \(errno)"))
      return
    }

    // Accept one connection
    let client = accept(sock, nil, nil)
    guard client >= 0 else {
      continuation.resume(throwing: CodexOAuthError.serverError("accept() failed: \(errno)"))
      return
    }
    defer { close(client) }

    // Read HTTP request
    var requestBuffer = [UInt8](repeating: 0, count: 4096)
    let bytesRead = read(client, &requestBuffer, requestBuffer.count)
    guard bytesRead > 0 else {
      continuation.resume(throwing: CodexOAuthError.serverError("read() returned \(bytesRead)"))
      return
    }

    let request = String(decoding: requestBuffer[0..<bytesRead], as: UTF8.self)

    // Parse request line
    guard let firstLine = request.split(separator: "\r\n").first.map(String.init) else {
      sendResponse(client, status: 400, body: htmlPage(title: "Error", body: "Bad request"))
      continuation.resume(throwing: CodexOAuthError.serverError("Bad request"))
      return
    }

    // GET /auth/callback?code=...&state=... HTTP/1.1
    let parts = firstLine.split(separator: " ")
    guard parts.count >= 2, let path = parts.dropFirst().first.map(String.init) else {
      sendResponse(client, status: 400, body: htmlPage(title: "Error", body: "Bad request"))
      continuation.resume(throwing: CodexOAuthError.serverError("Bad request line"))
      return
    }

    // Parse the path
    guard
      let urlComponents = URLComponents(string: path),
      urlComponents.path == "/auth/callback"
    else {
      sendResponse(client, status: 404, body: htmlPage(title: "Not Found", body: "Callback route not found."))
      continuation.resume(throwing: CodexOAuthError.serverError("Not found: \(path)"))
      return
    }

    let params = urlComponents.queryItems?.reduce(into: [String: String]()) { dict, item in
      dict[item.name] = item.value
    } ?? [:]

    guard params["state"] == expectedState else {
      sendResponse(client, status: 400, body: htmlPage(title: "Error", body: "State mismatch."))
      continuation.resume(throwing: CodexOAuthError.stateMismatch)
      return
    }

    guard let code = params["code"], !code.isEmpty else {
      sendResponse(client, status: 400, body: htmlPage(title: "Error", body: "Missing authorization code."))
      continuation.resume(throwing: CodexOAuthError.missingAuthorizationCode)
      return
    }

    sendResponse(client, status: 200, body: htmlPage(title: "Authenticated", body: "OpenAI authentication completed. You can close this window."))
    continuation.resume(returning: code)
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
      Darwin.send(sock, $0, strlen($0), 0)
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
    case .serverError(let msg):
      return "Callback server error: \(msg)"
    }
  }
}
