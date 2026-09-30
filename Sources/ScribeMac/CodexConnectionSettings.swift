import Chroma
import Foundation
import Observation
import ScribeCodexAuth
import ScribeKit

@MainActor @Observable
public final class CodexConnectionSettings {
  public var serverOrigin = ""
  public var sshTunnel = false
  public private(set) var consent: String?
  public private(set) var status: String?
  public private(set) var busy = false
  public var confirmsRemoval = false
  private var consentAccount: String?
  private var consentTunnel = false
  private let baseDirectory: URL?
  private let bearer: @Sendable () async throws -> String

  public init(baseDirectory: URL? = nil, bearer: @escaping @Sendable () async throws -> String = { try CodexDeviceIdentity.bearer() }) {
    self.baseDirectory = baseDirectory
    self.bearer = bearer
    try? CodexAuthority.finishCommittedCleanup(baseDirectory: baseDirectory)
    if let state = try? CodexAuthority.state(baseDirectory: baseDirectory) {
      switch state {
      case .serverOwned(let authority): serverOrigin = authority.origin; sshTunnel = authority.sshTunnel
      case .handoffPending(let pending): serverOrigin = pending.origin; sshTunnel = pending.sshTunnel
      default: break
      }
    }
  }

  public func requestConsent(origin: String? = nil) {
    do {
      let origin = try CodexServerTransport.origin(origin ?? serverOrigin, sshTunnel: sshTunnel)
      let account: String?
      switch try CodexAuthority.state(baseDirectory: baseDirectory) {
      case .local: account = try CodexCredentialStore.read(baseDirectory: baseDirectory)?.accountId
      case .handoffPending(let pending):
        guard pending.origin == origin, pending.sshTunnel == sshTunnel else { throw CodexAuthorityError.conflict }
        account = pending.accountID
      case .serverOwned(let authority):
        status = "Codex is owned by \(authority.origin). No automatic migration."
        return
      case .recoveryRequired: throw CodexAuthorityError.recoveryRequired
      }
      serverOrigin = origin; consent = origin; consentAccount = account; consentTunnel = sshTunnel
      status = nil
    } catch { status = "Use HTTPS, or explicitly select a loopback SSH tunnel. Resolve pending ownership before changing servers." }
  }

  public var consentMessage: String? {
    guard let consent else { return nil }
    if let consentAccount {
      return "Transfer account \(consentAccount) to \(consent)? This server will store and exclusively refresh your login. Authorized devices receive bearer access tokens. Stop or update older Scribe processes before transfer."
    }
    return "Trust \(consent) for access-only Codex credentials? This device must be explicitly authorized by its owner."
  }

  public func cancelConsent() { consent = nil; consentAccount = nil }

  public func confirm() {
    guard !busy, let origin = consent, origin == serverOrigin, consentTunnel == sshTunnel else { return }
    let account = consentAccount
    let tunnel = consentTunnel
    consent = nil; busy = true
    Task {
      defer { busy = false }
      do {
        let client = try CodexBrokerClient(origin: origin, sshTunnel: tunnel, bearer: bearer)
        let authority: CodexServerAuthority
        if let account { authority = try await client.transfer(accountID: account, baseDirectory: baseDirectory) }
        else { authority = try await client.connect(baseDirectory: baseDirectory) }
        CodexServerProviders.register(CodexBrokerAccessProvider(client: client, authority: authority), authority: authority)
        let paths = try ConfigLoader.resolvePaths()
        try ConfigLoader.upsertCodexProfile(at: paths.configPath)
        status = "Codex access is server-owned at \(origin)."
      } catch { status = "Connection unavailable. A pending transfer stays frozen; retry with the same server." }
    }
  }

  public func restoreProvider() {
    guard case .serverOwned(let authority) = try? CodexAuthority.state(baseDirectory: baseDirectory),
      let client = try? CodexBrokerClient(origin: authority.origin, sshTunnel: authority.sshTunnel, bearer: bearer) else { return }
    CodexServerProviders.register(CodexBrokerAccessProvider(client: client, authority: authority), authority: authority)
  }

  public func disconnect(removeSharedLogin: Bool = false) {
    guard !busy, case .serverOwned(let authority) = try? CodexAuthority.state(baseDirectory: baseDirectory) else { return }
    busy = true
    Task {
      defer { busy = false }
      do {
        let client = try CodexBrokerClient(origin: authority.origin, sshTunnel: authority.sshTunnel, bearer: bearer)
        if removeSharedLogin {
          try await client.removeConnection()
          try CodexAuthority.prepareNewLogin(afterRemovalOf: authority, status: await client.status(), baseDirectory: baseDirectory)
        } else { try await client.disconnect() }
        CodexServerProviders.register(DisconnectedCodexProvider(), authority: authority)
        status = removeSharedLogin ? "Shared login removed. Issued tokens expire at provider expiry." : "This device is disconnected. Server work continues."
      } catch { status = "Disconnect unavailable. Ownership remains server-side." }
    }
  }

  public func discardFailedRefresh() {
    do { try CodexAuthority.discardFailedLocalRefresh(baseDirectory: baseDirectory); status = "Old local credential discarded. Sign in again." }
    catch { status = "Only a failed local refresh can be discarded here. Server ownership remains unchanged." }
  }

  public func exportDeviceIdentity() {
    do {
      let identity = try CodexDeviceIdentity.enrollment()
      let path = CodexCredentialStore.resolveBaseDirectory().appendingPathComponent("\(identity.thumbprint).jwk")
      try identity.jwk.write(to: path, options: .atomic)
      status = "Public enrollment key: \(path.path). Ask the owner to enroll and explicitly authorize this device."
    } catch { status = "Could not export device public key." }
  }
}

private struct DisconnectedCodexProvider: CodexAccessCredentialProvider {
  func credential(rejectingAccessToken: String?) async throws -> CodexAccessCredential { throw CodexAuthorityError.denied }
}

public struct CodexConnectionBlock: Block {
  let settings: CodexConnectionSettings
  public init(settings: CodexConnectionSettings) { self.settings = settings }
  @MainActor public var body: some Block {
    VStack(spacing: 6) {
      TextEditor("Codex server origin", fontScale: 0.6, singleLine: true,
        text: { settings.serverOrigin }, onChange: { settings.serverOrigin = $0; settings.cancelConsent() })
      Button(settings.sshTunnel ? "SSH tunnel: on (loopback HTTP)" : "SSH tunnel: off (HTTPS required)", fontScale: 0.6) {
        settings.sshTunnel.toggle(); settings.cancelConsent()
      }
      Button(settings.busy ? "Connecting..." : "Use this server for Codex", fontScale: 0.6) { settings.requestConsent() }
      if let message = settings.consentMessage {
        Text(message).fontScale(0.55)
        Button("I trust this server — confirm", fontScale: 0.6) { settings.confirm() }
        Button("Cancel", fontScale: 0.6) { settings.cancelConsent() }
      }
      Button("Export Scribe device public key", fontScale: 0.6) { settings.exportDeviceIdentity() }
      Button("Disconnect this device", fontScale: 0.6) { settings.disconnect() }
      Button("Remove shared login...", fontScale: 0.6) { settings.confirmsRemoval.toggle() }
      if settings.confirmsRemoval {
        Text("Owner only: stop shared Codex work for every device. A new browser login is required.").fontScale(0.55)
        Button("Confirm removal for everyone", fontScale: 0.6) {
          settings.confirmsRemoval = false; settings.disconnect(removeSharedLogin: true)
        }
      }
      Button("Discard failed local refresh", fontScale: 0.6) { settings.discardFailedRefresh() }
      if let status = settings.status { Text(status).fontScale(0.55) }
    }
  }
}
