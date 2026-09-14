import AsyncHTTPClient
import Foundation
import NIOCore
import Subprocess

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

private actor CallbackServerReadiness {
  private var result: Result<Void, Error>?
  private var continuation: CheckedContinuation<Void, Error>?

  func wait() async throws {
    if let result {
      return try result.get()
    }

    try await withCheckedThrowingContinuation { continuation in
      self.continuation = continuation
    }
  }

  func resolve(_ result: Result<Void, Error>) {
    guard self.result == nil else { return }
    self.result = result
    continuation?.resume(with: result)
    continuation = nil
  }
}

public enum CodexOAuth {
  public static func login(baseDirectory: URL? = nil) async throws -> CodexCredential {
    try await login(
      callbackHost: CodexOAuthConstants.callbackHost,
      callbackPort: CodexOAuthConstants.callbackPort,
      browserOpener: openBrowser,
      baseDirectory: baseDirectory
    )
  }

  static func login(
    callbackHost: String,
    callbackPort: UInt16,
    browserOpener: @escaping @Sendable (URL) async -> Void,
    timeout: TimeInterval = CodexOAuthCallbackServer.loginTimeout,
    baseDirectory: URL? = nil
  ) async throws -> CodexCredential {
    let pkce = PKCE.generate()
    let state = generateState()

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

    let readiness = CallbackServerReadiness()
    async let codeTask = CodexOAuthCallbackServer.waitForCode(
      expectedState: state,
      host: callbackHost,
      port: callbackPort,
      timeout: timeout,
      onReady: { result in
        Task { await readiness.resolve(result) }
      }
    )

    do {
      try await readiness.wait()
    } catch {
      _ = try? await codeTask
      throw error
    }
    await browserOpener(authURL)

    let code = try await codeTask

    let tokenResponse = try await exchangeCode(code: code, verifier: pkce.verifier)

    let accountId = try extractAccountID(from: tokenResponse.accessToken)

    let expiresMs =
      Int64(Date().timeIntervalSince1970 * 1000)
      + Int64(tokenResponse.expiresIn) * 1000
    let credential = CodexCredential(
      access: tokenResponse.accessToken,
      refresh: tokenResponse.refreshToken,
      expires: expiresMs,
      accountId: accountId
    )

    try CodexCredentialStore.write(credential, baseDirectory: baseDirectory)

    return credential
  }

  public static func refresh(_ credential: CodexCredential, baseDirectory: URL? = nil) async throws -> CodexCredential {
    let tokenResponse = try await refreshAccessToken(refreshToken: credential.refresh)
    let accountId = try extractAccountID(from: tokenResponse.accessToken)

    let expiresMs =
      Int64(Date().timeIntervalSince1970 * 1000)
      + Int64(tokenResponse.expiresIn) * 1000
    let newCredential = CodexCredential(
      access: tokenResponse.accessToken,
      refresh: tokenResponse.refreshToken,
      expires: expiresMs,
      accountId: accountId
    )

    try CodexCredentialStore.write(newCredential, baseDirectory: baseDirectory)
    return newCredential
  }

  public static func getValidCredentials(baseDirectory: URL? = nil) async throws -> CodexCredential {
    guard let credential = try CodexCredentialStore.read(baseDirectory: baseDirectory) else {
      throw CodexOAuthError.noCredentials
    }
    if credential.isExpired {
      return try await refresh(credential, baseDirectory: baseDirectory)
    }
    return credential
  }

  public static func logout(baseDirectory: URL? = nil) throws {
    try CodexCredentialStore.delete(baseDirectory: baseDirectory)
  }

  private static func generateState() -> String {
    let bytes = secureRandomBytes(count: 16)
    return Data(bytes).map { String(format: "%02x", $0) }.joined()
  }

  private static func openBrowser(_ url: URL) async {
    #if os(macOS)
    _ = try? await Subprocess.run(
      .path("/usr/bin/open"),
      arguments: [url.absoluteString],
      output: .discarded,
      error: .discarded
    )
    #elseif os(Linux)
    _ = try? await Subprocess.run(
      .path("/usr/bin/xdg-open"),
      arguments: [url.absoluteString],
      output: .discarded,
      error: .discarded
    )
    #endif
  }

  private struct TokenResponse {
    let accessToken: String
    let refreshToken: String
    let expiresIn: Int
  }

  private static let httpClient: HTTPClient = {
    var config = HTTPClient.Configuration()
    config.redirectConfiguration = .disallow
    return HTTPClient(eventLoopGroupProvider: .singleton, configuration: config)
  }()

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
    let body = try await response.body.collect(upTo: 1_048_576)

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
    let body = try await response.body.collect(upTo: 1_048_576)

    guard response.status == .ok else {
      let bodyString = String(buffer: body)
      throw CodexOAuthError.tokenExchangeFailed(status: Int(response.status.code), body: bodyString)
    }

    return try parseTokenResponse(body)
  }

  private static func parseTokenResponse(_ body: ByteBuffer) throws -> TokenResponse {
    let bytes = body.getBytes(at: 0, length: body.readableBytes) ?? []
    let data = Data(bytes)

    guard !data.isEmpty else {
      throw CodexOAuthError.tokenExchangeFailed(
        status: 0, body: "Empty response body — token endpoint may have redirected (try again).")
    }

    let json: [String: Any]
    do {
      guard
        let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any]
      else {
        throw CodexOAuthError.tokenExchangeFailed(
          status: 0,
          body:
            "Response is not a JSON object: \(String(data: data, encoding: .utf8)?.prefix(500) ?? "<non-utf8>")"
        )
      }
      json = parsed
    } catch let error as CodexOAuthError {
      throw error
    } catch {
      throw CodexOAuthError.tokenExchangeFailed(
        status: 0,
        body:
          "JSON parse error: \(error.localizedDescription) — body: \(String(data: data, encoding: .utf8)?.prefix(500) ?? "<non-utf8>")"
      )
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

  static func extractAccountID(from jwt: String) throws -> String {
    let segments = jwt.split(separator: ".")
    guard segments.count >= 2 else {
      throw CodexOAuthError.invalidJWT
    }

    let payloadSegment = String(segments[1])
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
    var result =
      base64
      .replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")
    while result.count % 4 != 0 {
      result += "="
    }
    return result
  }
}

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
