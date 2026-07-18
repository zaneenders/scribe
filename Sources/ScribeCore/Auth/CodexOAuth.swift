import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

import AsyncHTTPClient
import NIOCore

// MARK: - OAuth Flow

public enum CodexOAuth {
  /// Run the full OAuth login flow:
  /// 1. Generate PKCE pair
  /// 2. Start callback server on localhost:1455
  /// 3. Open browser for user to authenticate
  /// 4. Capture authorization code from callback
  /// 5. Exchange code for access/refresh tokens
  /// 6. Persist credentials to disk
  ///
  /// - Returns: The newly created credential.
  public static func login() async throws -> CodexCredential {
    // 1. PKCE
    let pkce = PKCE.generate()
    let state = generateState()

    // 2. Build authorization URL
    var urlComponents = URLComponents(string: CodexOAuthConstants.authorizeURL)!
    urlComponents.queryItems = [
      URLQueryItem(name: "response_type", value: "code"),
      URLQueryItem(name: "client_id", value: CodexOAuthConstants.clientId),
      URLQueryItem(name: "redirect_uri", value: CodexOAuthConstants.redirectURI),
      URLQueryItem(name: "scope", value: CodexOAuthConstants.scope),
      URLQueryItem(name: "code_challenge", value: pkce.challenge),
      URLQueryItem(name: "code_challenge_method", value: "S256"),
      URLQueryItem(name: "state", value: state),
      URLQueryItem(name: "id_token_add_organizations", value: "true"),
      URLQueryItem(name: "codex_cli_simplified_flow", value: "true"),
      URLQueryItem(name: "originator", value: "pi"),
    ]
    let authURL = urlComponents.url!

    // 3. Start server and open browser concurrently
    let ready = DispatchSemaphore(value: 0)
    async let codeTask = CodexOAuthCallbackServer.waitForCode(
      expectedState: state,
      host: CodexOAuthConstants.callbackHost,
      port: CodexOAuthConstants.callbackPort,
      ready: ready
    )

    // Wait until the server is bound and listening, then open the browser.
    await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
      DispatchQueue.global().async {
        ready.wait()
        c.resume()
      }
    }
    openBrowser(authURL)

    let code = try await codeTask

    // 4. Exchange authorization code for tokens
    let tokenResponse = try await exchangeCode(code: code, verifier: pkce.verifier)

    // 5. Extract account ID from JWT
    let accountId = try extractAccountID(from: tokenResponse.accessToken)

    // 6. Build credential
    let expiresMs = Int64(Date().timeIntervalSince1970 * 1000)
      + Int64(tokenResponse.expiresIn) * 1000
    let credential = CodexCredential(
      access: tokenResponse.accessToken,
      refresh: tokenResponse.refreshToken,
      expires: expiresMs,
      accountId: accountId
    )

    // 7. Persist
    try CodexCredentialStore.write(credential)

    return credential
  }

  /// Refresh an expired (or about-to-expire) access token.
  /// Returns a new credential with updated tokens.
  public static func refresh(_ credential: CodexCredential) async throws -> CodexCredential {
    let tokenResponse = try await refreshAccessToken(refreshToken: credential.refresh)
    let accountId = try extractAccountID(from: tokenResponse.accessToken)

    let expiresMs = Int64(Date().timeIntervalSince1970 * 1000)
      + Int64(tokenResponse.expiresIn) * 1000
    let newCredential = CodexCredential(
      access: tokenResponse.accessToken,
      refresh: tokenResponse.refreshToken,
      expires: expiresMs,
      accountId: accountId
    )

    try CodexCredentialStore.write(newCredential)
    return newCredential
  }

  /// Get valid credentials, refreshing if necessary.
  /// Throws `CodexOAuthError.noCredentials` if not logged in.
  public static func getValidCredentials() async throws -> CodexCredential {
    guard let credential = try CodexCredentialStore.read() else {
      throw CodexOAuthError.noCredentials
    }
    if credential.isExpired {
      return try await refresh(credential)
    }
    return credential
  }

  /// Logout — delete stored credentials.
  public static func logout() throws {
    try CodexCredentialStore.delete()
  }

  /// Synchronous credential loader for init-time use.
  public static func loadCredentialsSync() throws -> CodexCredential {
    let semaphore = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var result: Result<CodexCredential, Error>?
    Task {
      do {
        let cred = try await getValidCredentials()
        result = .success(cred)
      } catch {
        result = .failure(error)
      }
      semaphore.signal()
    }
    semaphore.wait()
    switch result {
    case .success(let cred): return cred
    case .failure(let err): throw err
    case .none: throw CodexOAuthError.noCredentials
    }
  }

  // MARK: - Private

  private static func generateState() -> String {
    let bytes = secureRandomBytes(count: 16)
    return Data(bytes).map { String(format: "%02x", $0) }.joined()
  }

  private static func openBrowser(_ url: URL) {
    #if os(macOS)
    _ = try? Process.run(
      URL(fileURLWithPath: "/usr/bin/open"),
      arguments: [url.absoluteString]
    )
    #elseif os(Linux)
    _ = try? Process.run(
      URL(fileURLWithPath: "/usr/bin/xdg-open"),
      arguments: [url.absoluteString]
    )
    #endif
  }

  // MARK: - Token Exchange

  private struct TokenResponse {
    let accessToken: String
    let refreshToken: String
    let expiresIn: Int
  }

  private static let httpClient = HTTPClient(eventLoopGroupProvider: .singleton)

  private static func exchangeCode(code: String, verifier: String) async throws -> TokenResponse {
    var components = URLComponents()
    components.queryItems = [
      URLQueryItem(name: "grant_type", value: "authorization_code"),
      URLQueryItem(name: "client_id", value: CodexOAuthConstants.clientId),
      URLQueryItem(name: "code", value: code),
      URLQueryItem(name: "code_verifier", value: verifier),
      URLQueryItem(name: "redirect_uri", value: CodexOAuthConstants.redirectURI),
    ]

    var request = HTTPClientRequest(url: CodexOAuthConstants.tokenURL)
    request.method = .POST
    request.headers.add(name: "Content-Type", value: "application/x-www-form-urlencoded")
    request.body = .bytes(ByteBuffer(string: components.query ?? ""))

    let response = try await httpClient.execute(request, timeout: .seconds(30))
    let body = try await response.body.collect(upTo: 1_048_576) // 1 MiB

    guard response.status == .ok else {
      let bodyString = String(buffer: body)
      throw CodexOAuthError.tokenExchangeFailed(status: Int(response.status.code), body: bodyString)
    }

    return try parseTokenResponse(body)
  }

  private static func refreshAccessToken(refreshToken: String) async throws -> TokenResponse {
    var components = URLComponents()
    components.queryItems = [
      URLQueryItem(name: "grant_type", value: "refresh_token"),
      URLQueryItem(name: "refresh_token", value: refreshToken),
      URLQueryItem(name: "client_id", value: CodexOAuthConstants.clientId),
    ]

    var request = HTTPClientRequest(url: CodexOAuthConstants.tokenURL)
    request.method = .POST
    request.headers.add(name: "Content-Type", value: "application/x-www-form-urlencoded")
    request.body = .bytes(ByteBuffer(string: components.query ?? ""))

    let response = try await httpClient.execute(request, timeout: .seconds(30))
    let body = try await response.body.collect(upTo: 1_048_576) // 1 MiB

    guard response.status == .ok else {
      let bodyString = String(buffer: body)
      throw CodexOAuthError.tokenExchangeFailed(status: Int(response.status.code), body: bodyString)
    }

    return try parseTokenResponse(body)
  }

  private static func parseTokenResponse(_ body: ByteBuffer) throws -> TokenResponse {
    let bytes = body.getBytes(at: 0, length: body.readableBytes) ?? []
    let data = Data(bytes)

    guard
      let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
      throw CodexOAuthError.tokenExchangeFailed(status: 0, body: "Invalid JSON")
    }

    guard let accessToken = json["access_token"] as? String else {
      throw CodexOAuthError.missingToken("access_token")
    }
    guard let refreshToken = json["refresh_token"] as? String else {
      throw CodexOAuthError.missingToken("refresh_token")
    }
    guard let expiresIn = json["expires_in"] as? Int else {
      throw CodexOAuthError.missingToken("expires_in")
    }

    return TokenResponse(
      accessToken: accessToken,
      refreshToken: refreshToken,
      expiresIn: expiresIn
    )
  }

  // MARK: - JWT Parsing

  /// Extract the `chatgpt_account_id` from the JWT access token.
  /// Does NOT verify the signature — only decodes the payload.
  static func extractAccountID(from jwt: String) throws -> String {
    let segments = jwt.split(separator: ".")
    guard segments.count >= 2 else {
      throw CodexOAuthError.invalidJWT
    }

    let payloadSegment = String(segments[1])
    // Add padding for base64 decode
    let padded = padBase64(payloadSegment)

    guard let payloadData = Data(base64Encoded: padded) else {
      throw CodexOAuthError.invalidJWT
    }

    guard
      let payload = try JSONSerialization.jsonObject(with: payloadData) as? [String: Any],
      let auth = payload[CodexOAuthConstants.jwtClaimPath] as? [String: Any],
      let accountId = auth["chatgpt_account_id"] as? String,
      !accountId.isEmpty
    else {
      throw CodexOAuthError.noAccountID
    }

    return accountId
  }

  private static func padBase64(_ base64: String) -> String {
    var result = base64
      .replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")
    while result.count % 4 != 0 {
      result += "="
    }
    return result
  }
}

// MARK: - Secure Random Bytes (platform wrapper)

#if canImport(Darwin)
private func secureRandomBytes(count: Int) -> [UInt8] {
  var bytes = [UInt8](repeating: 0, count: count)
  _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
  return bytes
}
#elseif canImport(Glibc)
private func secureRandomBytes(count: Int) -> [UInt8] {
  var bytes = [UInt8](repeating: 0, count: count)
  let fd = open("/dev/urandom", O_RDONLY)
  precondition(fd >= 0, "Cannot open /dev/urandom")
  defer { close(fd) }
  let bytesRead = read(fd, &bytes, count)
  precondition(bytesRead == count, "Cannot read sufficient bytes from /dev/urandom")
  return bytes
}
#elseif canImport(Musl)
import Musl
private func secureRandomBytes(count: Int) -> [UInt8] {
  var bytes = [UInt8](repeating: 0, count: count)
  let fd = open("/dev/urandom", O_RDONLY)
  precondition(fd >= 0, "Cannot open /dev/urandom")
  defer { close(fd) }
  let bytesRead = read(fd, &bytes, count)
  precondition(bytesRead == count, "Cannot read sufficient bytes from /dev/urandom")
  return bytes
}
#endif
