import Foundation
import ScribeCore

struct ChatSessionMetadata: Codable, Sendable {
  var schemaVersion: Int
  var id: UUID
  var createdAt: Date
  var model: String
  var cwd: String
  var baseURL: String?
  var scribeVersion: String?

  init(
    schemaVersion: Int = 1,
    id: UUID,
    createdAt: Date,
    model: String,
    cwd: String,
    baseURL: String?,
    scribeVersion: String?
  ) {
    self.schemaVersion = schemaVersion
    self.id = id
    self.createdAt = createdAt
    self.model = model
    self.cwd = cwd
    self.baseURL = baseURL
    self.scribeVersion = scribeVersion
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
    guard !messages.isEmpty else { return }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let messagesURL = directory.appendingPathComponent("messages.jsonl", isDirectory: false)
    let writer = try AppendOnlyFileWriter(fileURL: messagesURL)
    for message in messages {
      var data = try enc.encode(message)
      data.append(UInt8(ascii: "\n"))
      try writer.append(data)
    }
    try FileManager.default.setAttributes(
      [.modificationDate: Date()],
      ofItemAtPath: directory.path
    )
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
