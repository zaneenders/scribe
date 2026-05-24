import Foundation
import _NIOFileSystem
import ScribeCore
import SystemPackage

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

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

  private static func metadataFile(in directory: FilePath) -> FilePath {
    directory.appendingPathComponent("metadata.json")
  }

  private static func messagesFile(in directory: FilePath) -> FilePath {
    directory.appendingPathComponent("messages.jsonl")
  }

  static func ensureSessionsDirectory(_ sessionsRoot: FilePath) async throws {
    try await FileSystem.shared.createDirectory(
      at: sessionsRoot,
      withIntermediateDirectories: true)
  }

  static func listSessionDirectories(
    sessionsRoot: FilePath,
    cwdFilter: String? = nil
  ) async throws -> [FilePath] {
    try await ensureSessionsDirectory(sessionsRoot)
    let fs = FileSystem.shared
    guard (try? await fs.info(forFileAt: sessionsRoot)) != nil else {
      return []
    }
    var sessionDirs: [FilePath] = []
    let names = try listDirectoryContents(sessionsRoot)
    for name in names where !name.hasPrefix(".") {
      let dir = sessionsRoot.appendingPathComponent(name)
      let st = FileStat.stat(dir)
      guard st.exists, st.isDirectory else { continue }
      let meta = metadataFile(in: dir)
      guard FileStat.stat(meta).exists else { continue }
      sessionDirs.append(dir)
    }
    if let cwd = cwdFilter {
      sessionDirs = sessionDirs.filter { dir in
        (try? loadMetadata(from: dir).cwd) == cwd
      }
    }
    return sessionDirs.sorted { a, b in
      modificationDate(of: a) > modificationDate(of: b)
    }
  }

  static func sessionDirectory(
    sessionId: UUID,
    sessionsRoot: FilePath
  ) async throws -> FilePath {
    try await ensureSessionsDirectory(sessionsRoot)
    return sessionsRoot.appendingPathComponent(sessionId.uuidString)
  }

  static func saveMetadata(_ metadata: ChatSessionMetadata, to directory: FilePath) async throws {
    try await FileSystem.shared.createDirectory(
      at: directory,
      withIntermediateDirectories: true)
    let metaData = try enc.encode(metadata)
    try metaData.write(to: URL(fileURLWithPath: metadataFile(in: directory).string), options: [.atomic])
  }

  static func loadMetadata(from directory: FilePath) throws -> ChatSessionMetadata {
    let metaData = try Data(contentsOf: URL(fileURLWithPath: metadataFile(in: directory).string))
    return try dec.decode(ChatSessionMetadata.self, from: metaData)
  }

  static func loadMessages(from directory: FilePath) throws -> [ScribeMessage] {
    let path = messagesFile(in: directory)
    guard FileStat.stat(path).exists else {
      return []
    }
    let data = try Data(contentsOf: URL(fileURLWithPath: path.string))
    let lines = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
    return lines.compactMap { line in
      try? dec.decode(ScribeMessage.self, from: Data(line))
    }
  }

  /// Keeps `messages.jsonl` open for repeated appends (e.g. one chat coordinator).
  final class MessagesAppender: Sendable {
    private let writer: AppendOnlyFileWriter
    private let directory: FilePath

    init(directory: FilePath) throws {
      self.directory = directory
      try createDirectoryWithIntermediates(directory)
      self.writer = try AppendOnlyFileWriter(filePath: messagesFile(in: directory))
    }

    func append(_ messages: [ScribeMessage]) throws {
      guard !messages.isEmpty else { return }
      for message in messages {
        var data = try ChatSessionStore.enc.encode(message)
        data.append(UInt8(ascii: "\n"))
        try writer.append(data)
      }
      try ChatSessionStore.touchModificationDate(of: directory)
    }
  }

  static func appendMessages(
    _ messages: [ScribeMessage],
    to directory: FilePath
  ) throws {
    guard !messages.isEmpty else { return }
    let appender = try MessagesAppender(directory: directory)
    try appender.append(messages)
  }

  private static func touchModificationDate(of directory: FilePath) throws {
    let now = Date().timeIntervalSince1970
    let times = timeval(
      tv_sec: Int(now),
      tv_usec: Int32((now - Double(Int(now))) * 1_000_000))
    var timevals = [times, times]
    if utimes(directory.string, &timevals) != 0 {
      throw ScribeError.generic("utimes failed for \(directory.string): errno \(errno)")
    }
  }

  /// Result of a successful fork.
  struct ForkResult: Sendable {
    let sessionId: UUID
    let sessionDirectory: FilePath
    let cutAt: Int
  }

  static func forkSession(
    from parentDirectory: FilePath,
    cutAt: Int,
    newSessionId: UUID,
    scribeVersion: String? = nil
  ) async throws -> ForkResult {
    let parentMeta = try loadMetadata(from: parentDirectory)
    let allMessages = try loadMessages(from: parentDirectory)
    let boundaries = allMessages.safeForkBoundaries()
    guard boundaries.contains(cutAt) else {
      throw ScribeError.invalidInput(
        message:
          "Cut index \(cutAt) is not a safe fork boundary (would split a tool round).")
    }
    let prefix = Array(allMessages.prefix(cutAt))

    let sessionsRoot = parentDirectory.removingLastComponent()
    let newDir = sessionsRoot.appendingPathComponent(newSessionId.uuidString)
    try await FileSystem.shared.createDirectory(
      at: newDir,
      withIntermediateDirectories: true)

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
    try await saveMetadata(newMeta, to: newDir)
    try appendMessages(prefix, to: newDir)
    return ForkResult(sessionId: newSessionId, sessionDirectory: newDir, cutAt: cutAt)
  }

  static func resolveResumeDirectory(
    specifier: String,
    sessionsRoot: FilePath,
    preferCWD: String? = nil
  ) async throws -> FilePath {
    let trimmed = specifier.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      throw ScribeError.invalidInput(message: "Empty --resume value.")
    }

    if trimmed.lowercased() == "latest" {
      let files = try await listSessionDirectories(sessionsRoot: sessionsRoot, cwdFilter: preferCWD)
      if let first = files.first {
        return first
      }
      let allFiles = try await listSessionDirectories(sessionsRoot: sessionsRoot)
      guard let first = allFiles.first else {
        throw ScribeError.resumeNotFound(specifier: "latest")
      }
      return first
    }

    let path = FilePath(NSString(string: trimmed).expandingTildeInPath)
    let st = FileStat.stat(path)
    if st.exists {
      if st.isDirectory {
        return path
      }
      let parent = path.removingLastComponent()
      if !parent.isEmpty, parent.string != "/" {
        return parent
      }
    }

    try await ensureSessionsDirectory(sessionsRoot)
    let lower = trimmed.lowercased()
    if let u = UUID(uuidString: lower) {
      let candidate = sessionsRoot.appendingPathComponent(u.uuidString)
      if (try? await FileSystem.shared.info(forFileAt: candidate)) != nil {
        return candidate
      }
    }

    let names = try listDirectoryContents(sessionsRoot)
    let matches = names.filter { $0.lowercased().hasPrefix(lower) }
    guard matches.count == 1, let only = matches.first else {
      if matches.isEmpty {
        throw ScribeError.resumeNotFound(specifier: trimmed)
      }
      throw ScribeError.resumeAmbiguous(specifier: trimmed)
    }
    return sessionsRoot.appendingPathComponent(only)
  }

  private static func modificationDate(of directory: FilePath) -> Date {
    FileStat.stat(directory).modificationDate
  }
}
