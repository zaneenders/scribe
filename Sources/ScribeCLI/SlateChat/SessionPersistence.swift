import Foundation
import ScribeCore
import ScribeLLM

// MARK: - SessionPersistence

/// Encapsulates all session file I/O so the coordinator doesn't know about
/// URLs, metadata schemas, or file formats.
actor SessionPersistence {
  private let url: URL
  nonisolated let sessionId: UUID
  nonisolated let createdAt: Date
  private var metadataWritten = false

  init(url: URL, sessionId: UUID, createdAt: Date) {
    self.url = url
    self.sessionId = sessionId
    self.createdAt = createdAt
  }

  /// Write metadata (new sessions only — no-op if already written).
  func writeMetadataOnce(model: String, cwd: String, baseURL: String) throws {
    guard !metadataWritten else { return }
    let meta = ChatSessionMetadata(
      id: sessionId,
      createdAt: createdAt,
      model: model,
      cwd: cwd,
      baseURL: baseURL,
      scribeVersion: GitVersion.hash
    )
    try ChatSessionStore.saveMetadata(meta, to: url)
    metadataWritten = true
  }

  /// Append messages to the session file.
  func append(_ messages: [Components.Schemas.ChatMessage]) throws {
    try ChatSessionStore.appendMessages(messages, to: url)
  }
}
