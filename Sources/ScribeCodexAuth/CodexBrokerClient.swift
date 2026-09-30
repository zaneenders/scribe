import AsyncHTTPClient
import Foundation
import NIOCore

public enum CodexServerTransport {
  public static func origin(_ value: String, sshTunnel: Bool = false) throws -> String {
    guard var parts = URLComponents(string: value), let host = parts.host?.lowercased(), !host.isEmpty,
      parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
      parts.path.isEmpty || parts.path == "/",
      parts.scheme == "https" || (sshTunnel && parts.scheme == "http" && ["127.0.0.1", "[::1]", "::1"].contains(host))
    else { throw CodexAuthorityError.invalidTransport }
    parts.host = host
    parts.path = ""
    if parts.scheme == "https" && parts.port == 443 { parts.port = nil }
    guard let result = parts.url?.absoluteString else { throw CodexAuthorityError.invalidTransport }
    return result
  }
}

public struct CodexBrokerClient: Sendable {
  public let origin: String
  public let sshTunnel: Bool
  private let bearer: @Sendable () async throws -> String
  private static let http: HTTPClient = {
    var configuration = HTTPClient.Configuration()
    configuration.redirectConfiguration = .disallow
    return HTTPClient(eventLoopGroupProvider: .singleton, configuration: configuration)
  }()

  public init(origin: String, sshTunnel: Bool = false, bearer: @escaping @Sendable () async throws -> String) throws {
    self.origin = try CodexServerTransport.origin(origin, sshTunnel: sshTunnel)
    self.sshTunnel = sshTunnel
    self.bearer = bearer
  }

  private func request(_ method: String, path: String, body: Data? = nil) async throws -> Data {
    do {
      var request = HTTPClientRequest(url: origin + "/sessions/codex/" + path)
      request.method = .init(rawValue: method)
      request.headers.add(name: "Authorization", value: "Bearer \(try await bearer())")
      request.headers.add(name: "Cache-Control", value: "no-store")
      if let body {
        request.headers.add(name: "Content-Type", value: "application/json")
        request.body = .bytes(ByteBuffer(bytes: body))
      }
      let response = try await Self.http.execute(request, timeout: .seconds(30))
      guard (200..<300).contains(response.status.code) else { throw CodexAuthorityError.denied }
      return Data(try await response.body.collect(upTo: 65_536).readableBytesView)
    } catch CodexAuthorityError.denied { throw CodexAuthorityError.denied }
    catch { throw CodexAuthorityError.unavailable }
  }

  private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
    do { return try JSONDecoder().decode(type, from: data) }
    catch { throw CodexAuthorityError.denied }
  }

  public func status() async throws -> CodexConnectionStatus {
    try decode(CodexConnectionStatus.self, from: await request("GET", path: "connection"))
  }
  public func handoff(_ value: CodexHandoffRequest) async throws -> CodexConnectionReceipt {
    try decode(CodexConnectionReceipt.self,
      from: await request("PUT", path: "connection", body: JSONEncoder().encode(value)))
  }
  public func access(_ value: CodexAccessRequest) async throws -> CodexAccessCredential {
    try decode(CodexAccessCredential.self,
      from: await request("POST", path: "access", body: JSONEncoder().encode(value)))
  }
  public func disconnect() async throws { _ = try await request("DELETE", path: "device-access") }
  public func removeConnection() async throws { _ = try await request("DELETE", path: "connection") }

  public func transfer(accountID: String, baseDirectory: URL? = nil) async throws -> CodexServerAuthority {
    let state = try CodexAuthority.state(baseDirectory: baseDirectory)
    let pending: CodexPendingHandoff
    if case .handoffPending(let existing) = state {
      guard existing.origin == origin, existing.sshTunnel == sshTunnel, existing.accountID == accountID else {
        throw CodexAuthorityError.conflict
      }
      pending = existing
    } else {
      let status = try await status()
      guard status.connection == nil else { throw CodexAuthorityError.conflict }
      pending = try await CodexAuthority.freeze(origin: origin, sshTunnel: sshTunnel,
        accountID: accountID, expectedGeneration: status.generation, baseDirectory: baseDirectory)
    }
    // Resolve a lost acknowledgement before resending any secret.
    let status = try await status()
    let receipt: CodexConnectionReceipt
    if let existing = status.receipts.first(where: { $0.handoffID == pending.id }) {
      receipt = existing
    } else {
      receipt = try await handoff(.init(handoffID: pending.id, expectedGeneration: pending.expectedGeneration,
        credential: CodexAuthority.export(pending, baseDirectory: baseDirectory)))
    }
    try CodexAuthority.commit(pending, receipt: receipt, baseDirectory: baseDirectory)
    return CodexServerAuthority(origin: origin, sshTunnel: sshTunnel, connectionID: receipt.connectionID,
      accountID: receipt.accountID, generation: receipt.generation)
  }

  public func connect(baseDirectory: URL? = nil) async throws -> CodexServerAuthority {
    guard let receipt = try await status().connection else { throw CodexAuthorityError.unavailable }
    let authority = CodexServerAuthority(origin: origin, sshTunnel: sshTunnel, connectionID: receipt.connectionID,
      accountID: receipt.accountID, generation: receipt.generation)
    _ = try await access(.init(connectionID: receipt.connectionID, generation: receipt.generation))
    try CodexAuthority.connect(authority, baseDirectory: baseDirectory)
    return authority
  }
}

public actor CodexBrokerAccessProvider: CodexAccessCredentialProvider {
  private let client: CodexBrokerClient
  private let authority: CodexServerAuthority
  private var cached: CodexAccessCredential?
  public init(client: CodexBrokerClient, authority: CodexServerAuthority) { self.client = client; self.authority = authority }
  public func credential(rejectingAccessToken: String? = nil) async throws -> CodexAccessCredential {
    let rejected = cached.flatMap { $0.access == rejectingAccessToken ? $0.lease : nil }
    do {
      let result = try await client.access(.init(connectionID: authority.connectionID,
        generation: authority.generation, rejectedLease: rejected))
      guard result.accountId == authority.accountID,
        result.expires > Int64(Date().timeIntervalSince1970 * 1000) else { throw CodexAuthorityError.conflict }
      cached = result
      return result
    } catch {
      // Only an unexpired, non-rejected access token may survive loss of connectivity.
      if (error as? CodexAuthorityError) == .unavailable, let cached, rejectingAccessToken == nil,
        cached.expires > Int64(Date().timeIntervalSince1970 * 1000) { return cached }
      cached = nil
      throw CodexAuthorityError.unavailable
    }
  }
  public func disconnect() async throws { cached = nil; try await client.disconnect() }
}
