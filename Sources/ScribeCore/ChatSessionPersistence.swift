import Foundation
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

public enum ChatSessionStore {

  /// Resolved session root (creates directories). Reads ``AgentConfig/chatSessionsDirectoryPath``.
  public static func sessionsDirectoryURL(configuration: AgentConfig) throws -> URL {
    let path = configuration.chatSessionsDirectoryPath
    let url = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  /// All `*.json` session files under the configured sessions directory (newest first by modification time).
  public static func listSessionFiles(configuration: AgentConfig) throws -> [URL] {
    let root = try sessionsDirectoryURL(configuration: configuration)
    guard FileManager.default.fileExists(atPath: root.path) else {
      return []
    }
    let contents = try FileManager.default.contentsOfDirectory(
      at: root,
      includingPropertiesForKeys: [.contentModificationDateKey],
      options: [.skipsHiddenFiles]
    )
    let jsonFiles = contents.filter { $0.pathExtension.lowercased() == "json" }
    return jsonFiles.sorted { a, b in
      let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        ?? .distantPast
      let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        ?? .distantPast
      return da > db
    }
  }

  public static func fileURL(sessionId: UUID, configuration: AgentConfig) throws -> URL {
    try sessionsDirectoryURL(configuration: configuration).appendingPathComponent(
      "\(sessionId.uuidString).json", isDirectory: false)
  }

  public static func save(_ archive: ChatSessionArchive, to url: URL) throws {
    let enc = JSONEncoder()
    enc.outputFormatting = [.sortedKeys]
    enc.dateEncodingStrategy = .iso8601
    let data = try enc.encode(archive)
    try data.write(to: url, options: [.atomic])
  }

  public static func load(from url: URL) throws -> ChatSessionArchive {
    let data = try Data(contentsOf: url)
    let dec = JSONDecoder()
    dec.dateDecodingStrategy = .iso8601
    let archive = try dec.decode(ChatSessionArchive.self, from: data)
    guard archive.messages.first?.role == .system else {
      throw AgentAPIError(description: "Session file missing leading system message.")
    }
    return archive
  }

  /// Resolves `path`, `UUID` / prefix, or the token `latest` (most recently modified file in the session directory).
  public static func resolveResumeURL(specifier: String, configuration: AgentConfig) throws -> URL {
    let trimmed = specifier.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      throw AgentAPIError(description: "Empty --resume value.")
    }

    if trimmed.lowercased() == "latest" {
      let files = try listSessionFiles(configuration: configuration)
      guard let first = files.first else {
        throw AgentAPIError(description: "No saved chat sessions found (use `scribe chat --sessions`).")
      }
      return first
    }

    let pathURL = URL(fileURLWithPath: NSString(string: trimmed).expandingTildeInPath)
    if FileManager.default.fileExists(atPath: pathURL.path) {
      return pathURL.standardizedFileURL
    }

    let root = try sessionsDirectoryURL(configuration: configuration)
    let lower = trimmed.lowercased()
    if let u = UUID(uuidString: lower) {
      let candidate = root.appendingPathComponent("\(u.uuidString).json")
      if FileManager.default.fileExists(atPath: candidate.path) {
        return candidate
      }
    }

    let contents = (try? FileManager.default.contentsOfDirectory(
      at: root,
      includingPropertiesForKeys: nil,
      options: [.skipsHiddenFiles]
    )) ?? []
    let matches = contents.filter { $0.lastPathComponent.lowercased().hasPrefix(lower) }
    guard matches.count == 1, let only = matches.first else {
      if matches.isEmpty {
        throw AgentAPIError(description: "No session matches “\(trimmed)”. Try `scribe chat --sessions`.")
      }
      throw AgentAPIError(description: "Ambiguous session prefix “\(trimmed)”; use a longer id or a full path.")
    }
    return only
  }
}
