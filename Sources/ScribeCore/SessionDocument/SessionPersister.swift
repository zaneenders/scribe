import Foundation
import SystemPackage

public struct SessionPersistenceSnapshot: Sendable {
  public let sessionId: UUID
  public let directory: FilePath
  public let messages: [ScribeMessage]

  public init(_ document: borrowing SessionDocument) {
    sessionId = document.sessionId
    directory = document.directory
    var msgs: [ScribeMessage] = []
    msgs.reserveCapacity(document.count)
    for i in 0..<document.count {
      msgs.append(document[i])
    }
    messages = msgs
  }
}

public protocol SessionPersister: Sendable {

  func append(_ messages: [ScribeMessage]) async throws

  func directory(for newSessionId: UUID) -> FilePath

  func openSession(
    _ snapshot: SessionPersistenceSnapshot,
    parent: SessionParent
  ) async throws
}

public final class InMemorySessionPersister: SessionPersister {
  public init() {}

  public func append(_ messages: [ScribeMessage]) async throws {}

  public func directory(for newSessionId: UUID) -> FilePath {
    FilePath("/in-memory/\(newSessionId.uuidString)")
  }

  public func openSession(
    _ snapshot: SessionPersistenceSnapshot,
    parent: SessionParent
  ) async throws {}
}
