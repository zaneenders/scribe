import Foundation
import Synchronization
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#else
import Musl
#endif

public enum CodexAuthorityError: String, Error, LocalizedError, CustomStringConvertible {
  case denied, unavailable, busy, frozen, conflict, invalidTransport, recoveryRequired
  public var description: String {
    switch self {
    case .frozen: "Codex ownership transfer is pending. Reconnect to the consented server to resolve it."
    case .recoveryRequired: "Codex refresh needs recovery. Do not replay the previous refresh token."
    default: "Codex credential authority: \(rawValue)."
    }
  }
  public var errorDescription: String? { description }
}

// A separate, stable inode coordinates every process, including atomic file replacement.
public final class CodexStoreLock: Sendable {
  private let descriptor: Mutex<Int32?>

  public init(directory: URL, name: String = "codex-authority.lock") throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
    guard attributes[.type] as? FileAttributeType == .typeDirectory else { throw CodexAuthorityError.unavailable }
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    let fd = open(directory.appendingPathComponent(name).path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard fd >= 0 else { throw CodexAuthorityError.unavailable }
    guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
      close(fd)
      throw CodexAuthorityError.busy
    }
    descriptor = Mutex(fd)
  }

  public static func acquire(directory: URL) async throws -> CodexStoreLock {
    while true {
      try Task.checkCancellation()
      do { return try CodexStoreLock(directory: directory) }
      catch CodexAuthorityError.busy { try await Task.sleep(for: .milliseconds(25)) }
    }
  }

  public func release() {
    descriptor.withLock { descriptor in
      if let fd = descriptor { _ = flock(fd, LOCK_UN); close(fd) }
      descriptor = nil
    }
  }
  deinit { release() }
}

public enum CodexSecureFile {
  public static func write<T: Encodable>(_ value: T, to url: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(value)
    let directory = url.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    let temporary = directory.appendingPathComponent(".\(UUID().uuidString)")
    let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard fd >= 0 else { throw CodexAuthorityError.unavailable }
    defer { close(fd); try? FileManager.default.removeItem(at: temporary) }
    try data.withUnsafeBytes { bytes in
      var offset = 0
      while offset < bytes.count {
        let count = systemWrite(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
        guard count > 0 else { throw CodexAuthorityError.unavailable }
        offset += count
      }
    }
    guard fsync(fd) == 0, rename(temporary.path, url.path) == 0 else { throw CodexAuthorityError.unavailable }
    try sync(directory)
  }

  public static func sync(_ directory: URL) throws {
    let fd = open(directory.path, O_RDONLY | O_CLOEXEC)
    guard fd >= 0 else { throw CodexAuthorityError.unavailable }
    defer { close(fd) }
    guard fsync(fd) == 0 else { throw CodexAuthorityError.unavailable }
  }
}

public struct CodexServerAuthority: Codable, Equatable, Sendable {
  public let origin: String
  public let sshTunnel: Bool
  public let connectionID: UUID
  public let accountID: String
  public let generation: Int

  public init(origin: String, sshTunnel: Bool, connectionID: UUID, accountID: String, generation: Int) {
    self.origin = origin
    self.sshTunnel = sshTunnel
    self.connectionID = connectionID
    self.accountID = accountID
    self.generation = generation
  }
}

public struct CodexPendingHandoff: Codable, Equatable, Sendable {
  public let id: UUID
  public let origin: String
  public let sshTunnel: Bool
  public let accountID: String
  public let expectedGeneration: Int
}

public enum CodexAuthorityState: Codable, Equatable, Sendable {
  case local
  case handoffPending(CodexPendingHandoff)
  case serverOwned(CodexServerAuthority)
  case recoveryRequired
}

public enum CodexAuthority {
  public static var hasLogin: Bool {
    guard let state = try? state() else { return false }
    switch state {
    case .serverOwned: return true
    case .local: return (try? CodexCredentialStore.read()) != nil
    default: return false
    }
  }

  static func path(_ directory: URL) -> URL { directory.appendingPathComponent("codex-authority.json") }

  public static func state(baseDirectory: URL? = nil) throws -> CodexAuthorityState {
    let path = path(baseDirectory ?? CodexCredentialStore.resolveBaseDirectory())
    guard FileManager.default.fileExists(atPath: path.path) else { return .local }
    do { return try JSONDecoder().decode(CodexAuthorityState.self, from: Data(contentsOf: path)) }
    catch { throw CodexAuthorityError.unavailable }
  }

  static func requireLocal(_ directory: URL) throws {
    guard try state(baseDirectory: directory) == .local else { throw CodexAuthorityError.frozen }
  }

  public static func finishCommittedCleanup(baseDirectory: URL? = nil) throws {
    let directory = baseDirectory ?? CodexCredentialStore.resolveBaseDirectory()
    let lock = try CodexStoreLock(directory: directory)
    defer { withExtendedLifetime(lock) {} }
    guard case .serverOwned = try state(baseDirectory: directory) else { return }
    try CodexCredentialStore.deleteRaw(baseDirectory: directory)
    try CodexSecureFile.sync(directory)
  }

  public static func freeze(origin: String, sshTunnel: Bool = false, accountID: String,
    expectedGeneration: Int, baseDirectory: URL? = nil
  ) async throws -> CodexPendingHandoff {
    let origin = try CodexServerTransport.origin(origin, sshTunnel: sshTunnel)
    let directory = baseDirectory ?? CodexCredentialStore.resolveBaseDirectory()
    let lock = try await CodexStoreLock.acquire(directory: directory)
    defer { withExtendedLifetime(lock) {} }
    if case .handoffPending(let pending) = try state(baseDirectory: directory) {
      guard pending.origin == origin, pending.sshTunnel == sshTunnel, pending.accountID == accountID,
        pending.expectedGeneration == expectedGeneration else { throw CodexAuthorityError.conflict }
      return pending
    }
    try requireLocal(directory)
    guard let credential = try CodexCredentialStore.readRaw(baseDirectory: directory),
      credential.accountId == accountID else { throw CodexAuthorityError.conflict }
    let pending = CodexPendingHandoff(id: UUID(), origin: origin, sshTunnel: sshTunnel,
      accountID: accountID, expectedGeneration: expectedGeneration)
    try CodexSecureFile.write(CodexAuthorityState.handoffPending(pending), to: path(directory))
    return pending
  }

  public static func export(_ pending: CodexPendingHandoff, baseDirectory: URL? = nil) throws -> CodexCredential {
    let directory = baseDirectory ?? CodexCredentialStore.resolveBaseDirectory()
    let lock = try CodexStoreLock(directory: directory)
    defer { withExtendedLifetime(lock) {} }
    guard try state(baseDirectory: directory) == .handoffPending(pending),
      let credential = try CodexCredentialStore.readRaw(baseDirectory: directory),
      credential.accountId == pending.accountID else { throw CodexAuthorityError.conflict }
    return credential
  }

  public static func commit(_ pending: CodexPendingHandoff, receipt: CodexConnectionReceipt,
    baseDirectory: URL? = nil
  ) throws {
    let directory = baseDirectory ?? CodexCredentialStore.resolveBaseDirectory()
    let lock = try CodexStoreLock(directory: directory)
    defer { withExtendedLifetime(lock) {} }
    let authority = CodexServerAuthority(origin: pending.origin, sshTunnel: pending.sshTunnel,
      connectionID: receipt.connectionID, accountID: receipt.accountID, generation: receipt.generation)
    let current = try state(baseDirectory: directory)
    guard receipt.handoffID == pending.id, receipt.accountID == pending.accountID,
      receipt.generation == pending.expectedGeneration + 1,
      current == .handoffPending(pending) || current == .serverOwned(authority)
    else { throw CodexAuthorityError.conflict }
    // Persist the fence before deletion: a crash can leave a credential, never refresh permission.
    try CodexSecureFile.write(CodexAuthorityState.serverOwned(authority), to: path(directory))
    try CodexCredentialStore.deleteRaw(baseDirectory: directory)
    try CodexSecureFile.sync(directory)
  }

  public static func prepareNewLogin(afterRemovalOf authority: CodexServerAuthority, status: CodexConnectionStatus,
    baseDirectory: URL? = nil
  ) throws {
    let directory = baseDirectory ?? CodexCredentialStore.resolveBaseDirectory()
    let lock = try CodexStoreLock(directory: directory)
    defer { withExtendedLifetime(lock) {} }
    guard try state(baseDirectory: directory) == .serverOwned(authority), status.connection == nil,
      status.generation > authority.generation else { throw CodexAuthorityError.conflict }
    try CodexCredentialStore.deleteRaw(baseDirectory: directory)
    try CodexSecureFile.sync(directory)
    try CodexSecureFile.write(CodexAuthorityState.local, to: path(directory))
  }

  public static func discardFailedLocalRefresh(baseDirectory: URL? = nil) throws {
    let directory = baseDirectory ?? CodexCredentialStore.resolveBaseDirectory()
    let lock = try CodexStoreLock(directory: directory)
    defer { withExtendedLifetime(lock) {} }
    guard try state(baseDirectory: directory) == .recoveryRequired else { throw CodexAuthorityError.conflict }
    try CodexCredentialStore.deleteRaw(baseDirectory: directory)
    try CodexSecureFile.sync(directory)
    try CodexSecureFile.write(CodexAuthorityState.local, to: path(directory))
  }

  public static func connect(_ authority: CodexServerAuthority, baseDirectory: URL? = nil) throws {
    _ = try CodexServerTransport.origin(authority.origin, sshTunnel: authority.sshTunnel)
    let directory = baseDirectory ?? CodexCredentialStore.resolveBaseDirectory()
    let lock = try CodexStoreLock(directory: directory)
    defer { withExtendedLifetime(lock) {} }
    guard try state(baseDirectory: directory) == .local,
      try CodexCredentialStore.readRaw(baseDirectory: directory) == nil else { throw CodexAuthorityError.conflict }
    try CodexSecureFile.write(CodexAuthorityState.serverOwned(authority), to: path(directory))
  }
}

private func systemWrite(_ fd: Int32, _ buffer: UnsafeRawPointer, _ count: Int) -> Int {
  #if canImport(Darwin)
  Darwin.write(fd, buffer, count)
  #elseif canImport(Glibc)
  Glibc.write(fd, buffer, count)
  #else
  Musl.write(fd, buffer, count)
  #endif
}
