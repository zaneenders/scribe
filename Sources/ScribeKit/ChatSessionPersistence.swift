import Foundation
import ScribeCore
import SystemPackage
import _NIOFileSystem

public struct ChatSessionMetadata: Codable, Sendable {
  public var schemaVersion: Int
  public var id: UUID
  public var createdAt: Date
  public var model: String
  public var cwd: String
  public var baseURL: String?
  public var scribeVersion: String?
  /// Written only when conversation messages are appended. Unlike a directory
  /// modification date, opening or otherwise touching a session cannot change it.
  public var lastMessageAt: Date?

  public var parentSessionId: UUID?

  public var forkedAtIndex: Int?

  public init(
    schemaVersion: Int = 2,
    id: UUID,
    createdAt: Date,
    model: String,
    cwd: String,
    baseURL: String?,
    scribeVersion: String?,
    lastMessageAt: Date? = nil,
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
    self.lastMessageAt = lastMessageAt
    self.parentSessionId = parentSessionId
    self.forkedAtIndex = forkedAtIndex
  }
}

public enum ChatSessionStore {

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

  private static func attachmentsDirectory(in directory: FilePath) -> FilePath {
    directory.appendingPathComponent("attachments")
  }

  private enum PersistedContentPart: Codable {
    case text(String)
    case imageURL(url: String, detail: String?)
    case imageReference(path: String, mimeType: String, detail: String?)

    private enum CodingKeys: String, CodingKey {
      case type, text, imageUrl = "image_url", path, mimeType = "mime_type", detail
    }

    private struct ImageURLPayload: Codable {
      let url: String
      let detail: String?
    }

    init(from decoder: any Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      switch try container.decode(String.self, forKey: .type) {
      case "text":
        self = .text(try container.decode(String.self, forKey: .text))
      case "image_url":
        let payload = try container.decode(ImageURLPayload.self, forKey: .imageUrl)
        self = .imageURL(url: payload.url, detail: payload.detail)
      case "image_ref":
        self = .imageReference(
          path: try container.decode(String.self, forKey: .path),
          mimeType: try container.decode(String.self, forKey: .mimeType),
          detail: try container.decodeIfPresent(String.self, forKey: .detail))
      default:
        throw DecodingError.dataCorruptedError(
          forKey: .type, in: container, debugDescription: "Unknown persisted content part")
      }
    }

    func encode(to encoder: any Encoder) throws {
      var container = encoder.container(keyedBy: CodingKeys.self)
      switch self {
      case .text(let text):
        try container.encode("text", forKey: .type)
        try container.encode(text, forKey: .text)
      case .imageURL(let url, let detail):
        try container.encode("image_url", forKey: .type)
        try container.encode(ImageURLPayload(url: url, detail: detail), forKey: .imageUrl)
      case .imageReference(let path, let mimeType, let detail):
        try container.encode("image_ref", forKey: .type)
        try container.encode(path, forKey: .path)
        try container.encode(mimeType, forKey: .mimeType)
        try container.encodeIfPresent(detail, forKey: .detail)
      }
    }
  }

  private struct PersistedMessage: Codable {
    let role: ScribeMessage.Role
    let content: [PersistedContentPart]
    let name: String?
    let toolCalls: [ScribeToolCall]?
    let toolCallId: String?
    let reasoning: String?

    private enum CodingKeys: String, CodingKey {
      case role, content, name
      case toolCalls = "tool_calls"
      case toolCallId = "tool_call_id"
      case reasoning = "reasoning_content"
    }

    init(_ message: ScribeMessage, directory: FilePath) throws {
      role = message.role
      name = message.name
      toolCalls = message.toolCalls
      toolCallId = message.toolCallId
      reasoning = message.reasoning
      content = try message.contentParts.map { part in
        switch part {
        case .text(let text):
          return .text(text)
        case .image(let url, let detail):
          guard let image = try ChatSessionStore.decodeImageDataURI(url) else {
            return .imageURL(url: url, detail: detail)
          }
          let filename =
            "\(UUID().uuidString).\(ChatSessionStore.fileExtension(for: image.mimeType))"
          let relativePath = "attachments/\(filename)"
          let attachments = ChatSessionStore.attachmentsDirectory(in: directory)
          try createDirectoryWithIntermediates(attachments)
          try image.data.write(
            to: URL(fileURLWithPath: attachments.appendingPathComponent(filename).string),
            options: [.atomic])
          return .imageReference(path: relativePath, mimeType: image.mimeType, detail: detail)
        }
      }
    }

    func hydrated(in directory: FilePath) throws -> ScribeMessage {
      let parts: [ScribeContentPart] = try content.map { part in
        switch part {
        case .text(let text):
          return .text(text)
        case .imageURL(let url, let detail):
          return .image(url: url, detail: detail)
        case .imageReference(let path, let mimeType, let detail):
          guard path.hasPrefix("attachments/"),
            !path.contains(".."),
            !path.dropFirst("attachments/".count).contains("/")
          else {
            throw ScribeError.sessionCorrupted(reason: "Invalid session attachment path: \(path)")
          }
          let data = try Data(
            contentsOf: URL(fileURLWithPath: directory.appendingPathComponent(path).string))
          return .image(
            url: "data:\(mimeType);base64,\(data.base64EncodedString())", detail: detail)
        }
      }
      return ScribeMessage(
        role: role,
        contentParts: parts,
        name: name,
        toolCalls: toolCalls,
        toolCallId: toolCallId,
        reasoning: reasoning)
    }
  }

  private static func decodeImageDataURI(_ value: String) throws -> (mimeType: String, data: Data)? {
    guard value.hasPrefix("data:") else { return nil }
    guard let separator = value.firstIndex(of: ",") else {
      throw ScribeError.sessionCorrupted(reason: "Malformed image data URI")
    }
    let metadata = String(value[value.index(value.startIndex, offsetBy: 5)..<separator])
    let fields = metadata.split(separator: ";", omittingEmptySubsequences: false)
    guard let mime = fields.first.map(String.init), mime.hasPrefix("image/"),
      fields.dropFirst().contains("base64"),
      let data = Data(base64Encoded: String(value[value.index(after: separator)...]))
    else {
      throw ScribeError.sessionCorrupted(reason: "Malformed base64 image data URI")
    }
    return (mime, data)
  }

  private static func fileExtension(for mimeType: String) -> String {
    switch mimeType.lowercased() {
    case "image/jpeg": return "jpg"
    case "image/png": return "png"
    case "image/gif": return "gif"
    case "image/webp": return "webp"
    case "image/bmp": return "bmp"
    case "image/tiff": return "tiff"
    case "image/heic": return "heic"
    case "image/heif": return "heif"
    default: return "img"
    }
  }

  public static func ensureSessionsDirectory(_ sessionsRoot: FilePath) async throws {
    try await FileSystem.shared.createDirectory(
      at: sessionsRoot,
      withIntermediateDirectories: true)
  }

  public static func listSessionDirectories(
    sessionsRoot: FilePath,
    cwdFilter: String? = nil
  ) async throws -> [FilePath] {
    try await ensureSessionsDirectory(sessionsRoot)
    let fs = FileSystem.shared
    guard (try? await fs.info(forFileAt: sessionsRoot)) != nil else {
      return []
    }
    // Capture the last-message date during discovery so the comparator does no
    // filesystem work. Directory mtimes are intentionally ignored: opening or
    // touching a session must not move it in conversation history.
    var sessions: [(directory: FilePath, lastMessageAt: Date)] = []
    let names = try listDirectoryContents(sessionsRoot)
    for name in names where !name.hasPrefix(".") {
      let dir = sessionsRoot.appendingPathComponent(name)
      let directoryStat = FileStat.stat(dir)
      guard directoryStat.exists, directoryStat.isDirectory else { continue }
      let metaPath = metadataFile(in: dir)
      guard FileStat.stat(metaPath).exists, let metadata = try? loadMetadata(from: dir) else { continue }
      if let cwd = cwdFilter, metadata.cwd != cwd {
        continue
      }
      sessions.append(
        (directory: dir, lastMessageAt: lastMessageDate(in: dir, metadata: metadata)))
    }
    return sessions.sorted { $0.lastMessageAt > $1.lastMessageAt }.map(\.directory)
  }

  public static func sessionDirectory(
    sessionId: UUID,
    sessionsRoot: FilePath
  ) async throws -> FilePath {
    try await ensureSessionsDirectory(sessionsRoot)
    return sessionsRoot.appendingPathComponent(sessionId.uuidString)
  }

  public static func saveMetadata(_ metadata: ChatSessionMetadata, to directory: FilePath) async throws {
    try await FileSystem.shared.createDirectory(
      at: directory,
      withIntermediateDirectories: true)
    let metaData = try enc.encode(metadata)
    try metaData.write(to: URL(fileURLWithPath: metadataFile(in: directory).string), options: [.atomic])
  }

  public static func loadMetadata(from directory: FilePath) throws -> ChatSessionMetadata {
    let metaData = try Data(contentsOf: URL(fileURLWithPath: metadataFile(in: directory).string))
    return try dec.decode(ChatSessionMetadata.self, from: metaData)
  }

  /// Returns the time conversation messages were last appended. Older sessions
  /// predate `lastMessageAt`, so use the messages file's modification time as a
  /// migration fallback; neither value changes merely because a session opens.
  public static func lastMessageDate(
    in directory: FilePath,
    metadata: ChatSessionMetadata? = nil
  ) -> Date {
    let metadata = metadata ?? (try? loadMetadata(from: directory))
    if let lastMessageAt = metadata?.lastMessageAt { return lastMessageAt }
    let messagesStat = FileStat.stat(messagesFile(in: directory))
    if messagesStat.exists { return messagesStat.modificationDate }
    return metadata?.createdAt ?? .distantPast
  }

  public static func loadMessages(from directory: FilePath) throws -> [ScribeMessage] {
    let path = messagesFile(in: directory)
    guard FileStat.stat(path).exists else {
      return []
    }
    let data = try Data(contentsOf: URL(fileURLWithPath: path.string))
    let lines = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
    return try lines.map { line in
      let lineData = Data(line)
      if let persisted = try? dec.decode(PersistedMessage.self, from: lineData) {
        return try persisted.hydrated(in: directory)
      }
      // Legacy sessions stored ScribeMessage directly, including inline data URIs.
      guard let message = try? dec.decode(ScribeMessage.self, from: lineData) else {
        throw ScribeError.sessionCorrupted(reason: "Unrecognized message format in session file")
      }
      return message
    }
  }

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
        let persisted = try PersistedMessage(message, directory: directory)
        var data = try ChatSessionStore.enc.encode(persisted)
        data.append(UInt8(ascii: "\n"))
        try writer.append(data)
      }
      try ChatSessionStore.recordLastMessageDate(in: directory, date: Date())
    }
  }

  public static func appendMessages(
    _ messages: [ScribeMessage],
    to directory: FilePath
  ) throws {
    guard !messages.isEmpty else { return }
    let appender = try MessagesAppender(directory: directory)
    try appender.append(messages)
  }

  private static func recordLastMessageDate(in directory: FilePath, date: Date) throws {
    // `appendMessages` is also a low-level utility used before metadata exists.
    guard FileStat.stat(metadataFile(in: directory)).exists else { return }
    var metadata = try loadMetadata(from: directory)
    metadata.lastMessageAt = date
    let data = try enc.encode(metadata)
    try data.write(
      to: URL(fileURLWithPath: metadataFile(in: directory).string),
      options: [.atomic])
  }

  public struct ForkResult: Sendable {
    public let sessionId: UUID
    public let sessionDirectory: FilePath
    public let cutAt: Int
  }

  public static func forkSession(
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

  public static func resolveResumeDirectory(
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
