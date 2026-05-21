import Foundation
import Logging
import ScribeCore

struct ChatSessionMetadata: Codable, Sendable {
  var schemaVersion: Int
  var id: UUID
  var createdAt: Date
  var model: String
  var cwd: String
  var baseURL: String?
  var scribeVersion: String?
  /// Session this one was forked from. `nil` for top-level (non-forked) sessions.
  var parentSessionId: UUID?
  /// Number of messages copied from the parent at fork time — i.e. the cut
  /// index in the parent's log. `nil` for non-forked sessions.
  var forkedAtIndex: Int?

  init(
    schemaVersion: Int = 2,
    id: UUID,
    createdAt: Date,
    model: String,
    cwd: String,
    baseURL: String?,
    scribeVersion: String?,
    parentSessionId: UUID? = nil,
    forkedAtIndex: Int? = nil
  ) {
    self.schemaVersion = schemaVersion
    self.id = id
    self.createdAt = createdAt
    self.model = model
    self.cwd = cwd
    self.baseURL = baseURL
    self.scribeVersion = scribeVersion
    self.parentSessionId = parentSessionId
    self.forkedAtIndex = forkedAtIndex
  }
}

enum ChatSessionStore {

  private static let enc: JSONEncoder = {
    let e = JSONEncoder()
    e.outputFormatting = [.sortedKeys]
    e.dateEncodingStrategy = .iso8601
    return e
  }()

  private static let dec: JSONDecoder = {
    let d = JSONDecoder()
    d.dateDecodingStrategy = .iso8601
    return d
  }()

  static func sessionsDirectoryURL(sessionsDirectoryPath: String) throws -> URL {
    let url = URL(fileURLWithPath: sessionsDirectoryPath, isDirectory: true).standardizedFileURL
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  static func listSessionFiles(
    sessionsDirectoryPath: String,
    cwdFilter: String? = nil
  ) throws -> [URL] {
    let root = try sessionsDirectoryURL(sessionsDirectoryPath: sessionsDirectoryPath)
    guard FileManager.default.fileExists(atPath: root.path) else {
      return []
    }
    let contents = try FileManager.default.contentsOfDirectory(
      at: root,
      includingPropertiesForKeys: [.contentModificationDateKey],
      options: [.skipsHiddenFiles]
    )
    var sessionDirs = contents.filter { url in
      var isDir: ObjCBool = false
      guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
        return false
      }
      let meta = url.appendingPathComponent("metadata.json", isDirectory: false)
      return FileManager.default.fileExists(atPath: meta.path)
    }
    if let cwd = cwdFilter {
      sessionDirs = sessionDirs.filter { url in
        (try? ChatSessionStore.loadMetadata(from: url).cwd) == cwd
      }
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

  static func sessionDirectoryURL(sessionId: UUID, sessionsDirectoryPath: String) throws -> URL {
    try sessionsDirectoryURL(sessionsDirectoryPath: sessionsDirectoryPath)
      .appendingPathComponent(sessionId.uuidString, isDirectory: true)
  }

  static func saveMetadata(_ metadata: ChatSessionMetadata, to directory: URL) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let metaURL = directory.appendingPathComponent("metadata.json", isDirectory: false)
    let metaData = try enc.encode(metadata)
    try metaData.write(to: metaURL, options: [.atomic])
  }

  static func loadMetadata(from directory: URL) throws -> ChatSessionMetadata {
    let metaURL = directory.appendingPathComponent("metadata.json", isDirectory: false)
    let metaData = try Data(contentsOf: metaURL)
    return try dec.decode(ChatSessionMetadata.self, from: metaData)
  }

  static func loadMessages(from directory: URL) throws -> [ScribeMessage] {
    let messagesURL = directory.appendingPathComponent("messages.jsonl", isDirectory: false)
    guard FileManager.default.fileExists(atPath: messagesURL.path) else {
      return []
    }
    let data = try Data(contentsOf: messagesURL)
    let lines = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
    return lines.compactMap { line in
      try? dec.decode(ScribeMessage.self, from: Data(line))
    }
  }

  static func appendMessages(
    _ messages: [ScribeMessage],
    to directory: URL
  ) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let messagesURL = directory.appendingPathComponent("messages.jsonl", isDirectory: false)

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

    try? FileManager.default.setAttributes(
      [.modificationDate: Date()],
      ofItemAtPath: directory.path
    )
  }

  /// Result of a successful fork.
  struct ForkResult: Sendable {
    let sessionId: UUID
    let sessionURL: URL
    let cutAt: Int
  }

  /// Fork a session at the given safe boundary into a new sibling session.
  ///
  /// Validates `cutAt` against `safeForkBoundaries()` so a fork cannot land
  /// inside a tool round. Copies messages `[0..cutAt)` into a freshly minted
  /// session directory whose metadata points back at the parent.
  ///
  /// - Parameters:
  ///   - parentDirectory: Existing session directory containing `metadata.json`
  ///     and `messages.jsonl`.
  ///   - cutAt: Number of messages from the parent to copy. Must be present
  ///     in `messages.safeForkBoundaries()`.
  ///   - newSessionId: UUID for the new session (caller provides so the host
  ///     can log it before the call lands).
  ///   - scribeVersion: Override for the `scribeVersion` field; defaults to
  ///     the parent's value.
  static func forkSession(
    from parentDirectory: URL,
    cutAt: Int,
    newSessionId: UUID,
    scribeVersion: String? = nil
  ) throws -> ForkResult {
    let parentMeta = try loadMetadata(from: parentDirectory)
    let allMessages = try loadMessages(from: parentDirectory)
    let boundaries = allMessages.safeForkBoundaries()
    guard boundaries.contains(cutAt) else {
      throw ScribeError.invalidInput(
        message:
          "Cut index \(cutAt) is not a safe fork boundary (would split a tool round).")
    }
    let prefix = Array(allMessages.prefix(cutAt))

    let sessionsRoot = parentDirectory.deletingLastPathComponent()
    let newDir = sessionsRoot.appendingPathComponent(
      newSessionId.uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
      at: newDir, withIntermediateDirectories: true)

    let newMeta = ChatSessionMetadata(
      id: newSessionId,
      createdAt: Date(),
      model: parentMeta.model,
      cwd: parentMeta.cwd,
      baseURL: parentMeta.baseURL,
      scribeVersion: scribeVersion ?? parentMeta.scribeVersion,
      parentSessionId: parentMeta.id,
      forkedAtIndex: cutAt
    )
    try saveMetadata(newMeta, to: newDir)
    try appendMessages(prefix, to: newDir)
    return ForkResult(sessionId: newSessionId, sessionURL: newDir, cutAt: cutAt)
  }

  static func resolveResumeURL(
    specifier: String,
    sessionsDirectoryPath: String,
    preferCWD: String? = nil
  ) throws -> URL {
    let trimmed = specifier.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      throw ScribeError.invalidInput(message: "Empty --resume value.")
    }

    if trimmed.lowercased() == "latest" {
      let files = try listSessionFiles(
        sessionsDirectoryPath: sessionsDirectoryPath, cwdFilter: preferCWD)
      if let first = files.first {
        return first
      }
      // Fall back to overall latest (any cwd)
      let allFiles = try listSessionFiles(sessionsDirectoryPath: sessionsDirectoryPath)
      guard let first = allFiles.first else {
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
}
