import Foundation
import Logging
import ScribeLLM

/// On-disk format for `scribe chat` session logs (JSON).
public struct ChatSessionArchive: Codable, Sendable, Equatable {
  public static let currentSchemaVersion = 1

  public var schemaVersion: Int
  public var id: UUID
  public var createdAt: Date
  public var updatedAt: Date
  public var cwd: String
  public var model: String
  public var baseURL: String?
  public var messages: [Components.Schemas.ChatMessage]

  public init(
    schemaVersion: Int = Self.currentSchemaVersion,
    id: UUID,
    createdAt: Date,
    updatedAt: Date,
    cwd: String,
    model: String,
    baseURL: String?,
    messages: [Components.Schemas.ChatMessage]
  ) {
    self.schemaVersion = schemaVersion
    self.id = id
    self.createdAt = createdAt
    self.updatedAt = updatedAt
    self.cwd = cwd
    self.model = model
    self.baseURL = baseURL
    self.messages = messages
  }
}

/// Metadata stored separately from messages so the archive can be updated incrementally.
private struct ChatSessionMetadata: Codable, Sendable {
  var schemaVersion: Int
  var id: UUID
  var createdAt: Date
  var model: String
  var cwd: String
  var baseURL: String?
}

public enum ChatSessionStore {

  /// Resolved session root (creates directories).
  public static func sessionsDirectoryURL(sessionsDirectoryPath: String) throws -> URL {
    let url = URL(fileURLWithPath: sessionsDirectoryPath, isDirectory: true).standardizedFileURL
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  /// All session directories under the configured sessions directory (newest first by modification time).
  public static func listSessionFiles(sessionsDirectoryPath: String) throws -> [URL] {
    let root = try sessionsDirectoryURL(sessionsDirectoryPath: sessionsDirectoryPath)
    guard FileManager.default.fileExists(atPath: root.path) else {
      return []
    }
    let contents = try FileManager.default.contentsOfDirectory(
      at: root,
      includingPropertiesForKeys: [.contentModificationDateKey],
      options: [.skipsHiddenFiles]
    )
    let sessionDirs = contents.filter { url in
      var isDir: ObjCBool = false
      guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
        return false
      }
      let meta = url.appendingPathComponent("metadata.json", isDirectory: false)
      return FileManager.default.fileExists(atPath: meta.path)
    }
    return sessionDirs.sorted { a, b in
      let da =
        (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        ?? .distantPast
      let db =
        (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        ?? .distantPast
      return da > db
    }
  }

  public static func sessionDirectoryURL(sessionId: UUID, sessionsDirectoryPath: String) throws -> URL {
    try sessionsDirectoryURL(sessionsDirectoryPath: sessionsDirectoryPath)
      .appendingPathComponent(sessionId.uuidString, isDirectory: true)
  }

  /// Write the full archive into a session directory as `metadata.json` + `messages.jsonl`.
  public static func save(_ archive: ChatSessionArchive, to directory: URL) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    let metadata = ChatSessionMetadata(
      schemaVersion: archive.schemaVersion,
      id: archive.id,
      createdAt: archive.createdAt,
      model: archive.model,
      cwd: archive.cwd,
      baseURL: archive.baseURL
    )

    let enc = JSONEncoder()
    enc.outputFormatting = [.sortedKeys]
    enc.dateEncodingStrategy = .iso8601

    let metaURL = directory.appendingPathComponent("metadata.json", isDirectory: false)
    let metaData = try enc.encode(metadata)
    try metaData.write(to: metaURL, options: [.atomic])

    let messagesURL = directory.appendingPathComponent("messages.jsonl", isDirectory: false)
    var messagesData = Data()
    for message in archive.messages {
      var line = try enc.encode(message)
      line.append(UInt8(ascii: "\n"))
      messagesData.append(line)
    }
    try messagesData.write(to: messagesURL, options: [.atomic])
  }

  /// Append messages to `messages.jsonl` inside a session directory.
  public static func appendMessages(
    _ messages: [Components.Schemas.ChatMessage],
    to directory: URL
  ) throws {
    let messagesURL = directory.appendingPathComponent("messages.jsonl", isDirectory: false)
    let enc = JSONEncoder()
    enc.outputFormatting = [.sortedKeys]
    enc.dateEncodingStrategy = .iso8601

    if !FileManager.default.fileExists(atPath: messagesURL.path) {
      _ = FileManager.default.createFile(atPath: messagesURL.path, contents: nil)
    }

    let handle = try FileHandle(forWritingTo: messagesURL)
    defer { try? handle.close() }
    try handle.seekToEnd()

    for message in messages {
      var data = try enc.encode(message)
      data.append(UInt8(ascii: "\n"))
      try handle.write(contentsOf: data)
    }

    // Touch the directory so listSessionFiles reflects recent activity.
    try? FileManager.default.setAttributes(
      [.modificationDate: Date()],
      ofItemAtPath: directory.path
    )
  }

  /// Read a session directory (`metadata.json` + `messages.jsonl`) into a ``ChatSessionArchive``.
  public static func load(from directory: URL) throws -> ChatSessionArchive {
    let metaURL = directory.appendingPathComponent("metadata.json", isDirectory: false)
    let messagesURL = directory.appendingPathComponent("messages.jsonl", isDirectory: false)

    let metaData = try Data(contentsOf: metaURL)
    let dec = JSONDecoder()
    dec.dateDecodingStrategy = .iso8601
    let metadata = try dec.decode(ChatSessionMetadata.self, from: metaData)

    var messages: [Components.Schemas.ChatMessage] = []
    if FileManager.default.fileExists(atPath: messagesURL.path) {
      let data = try Data(contentsOf: messagesURL)
      let lines = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
      for line in lines {
        if let message = try? dec.decode(Components.Schemas.ChatMessage.self, from: Data(line)) {
          messages.append(message)
        } else {
          break
        }
      }
    }

    guard messages.first?.role == .system else {
      throw ScribeError.sessionCorrupted(reason: "Session file missing leading system message.")
    }

    let updatedAt =
      (try? directory.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
      ?? Date()

    return ChatSessionArchive(
      schemaVersion: metadata.schemaVersion,
      id: metadata.id,
      createdAt: metadata.createdAt,
      updatedAt: updatedAt,
      cwd: metadata.cwd,
      model: metadata.model,
      baseURL: metadata.baseURL,
      messages: messages
    )
  }

  /// Resolves `path`, `UUID` / prefix, or the token `latest` (most recently modified directory in the session directory).
  public static func resolveResumeURL(specifier: String, sessionsDirectoryPath: String) throws -> URL {
    let trimmed = specifier.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      throw ScribeError.invalidInput(message: "Empty --resume value.")
    }

    if trimmed.lowercased() == "latest" {
      let files = try listSessionFiles(sessionsDirectoryPath: sessionsDirectoryPath)
      guard let first = files.first else {
        throw ScribeError.resumeNotFound(specifier: "latest")
      }
      return first
    }

    let pathURL = URL(fileURLWithPath: NSString(string: trimmed).expandingTildeInPath)
    var isDir: ObjCBool = false
    if FileManager.default.fileExists(atPath: pathURL.path, isDirectory: &isDir) {
      if isDir.boolValue {
        return pathURL.standardizedFileURL
      }
      // If it points to a file inside a session dir (e.g. metadata.json), return the parent.
      let parent = pathURL.deletingLastPathComponent()
      if parent.lastPathComponent != "/" {
        return parent.standardizedFileURL
      }
    }

    let root = try sessionsDirectoryURL(sessionsDirectoryPath: sessionsDirectoryPath)
    let lower = trimmed.lowercased()
    if let u = UUID(uuidString: lower) {
      let candidate = root.appendingPathComponent(u.uuidString, isDirectory: true)
      if FileManager.default.fileExists(atPath: candidate.path) {
        return candidate
      }
    }

    let contents =
      (try? FileManager.default.contentsOfDirectory(
        at: root,
        includingPropertiesForKeys: nil,
        options: [.skipsHiddenFiles]
      )) ?? []
    let matches = contents.filter { $0.lastPathComponent.lowercased().hasPrefix(lower) }
    guard matches.count == 1, let only = matches.first else {
      if matches.isEmpty {
        throw ScribeError.resumeNotFound(specifier: trimmed)
      }
      throw ScribeError.resumeAmbiguous(specifier: trimmed)
    }
    return only
  }

  /// Creates a conversation-persist callback that writes the full history on every call.
  public static func makePersistCallback(
    sessionId: UUID,
    createdAt: Date,
    model: String,
    baseURL: String?,
    persistURL: URL,
    logger: Logger
  ) -> @Sendable ([Components.Schemas.ChatMessage]) -> Void {
    return { history in
      let cwd = FileManager.default.currentDirectoryPath
      do {
        try save(
          ChatSessionArchive(
            id: sessionId,
            createdAt: createdAt,
            updatedAt: Date(),
            cwd: cwd,
            model: model,
            baseURL: baseURL,
            messages: history
          ),
          to: persistURL
        )
        logger.trace(
          """
          event=chat.persist.save \
          messages=\(history.count) \
          path=\(persistURL.path)
          """
        )
      } catch {
        logger.error(
          """
          event=chat.persist.fail \
          path=\(persistURL.path) \
          err="\(error.localizedDescription)"
          """
        )
      }
    }
  }
}
