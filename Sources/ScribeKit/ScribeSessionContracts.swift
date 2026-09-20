import Foundation
import ScribeCore

// MARK: - Session summaries

/// Transport-neutral description of a persisted session, suitable for lists
/// and sidebars. Mirrors the persisted `ChatSessionMetadata` without exposing
/// filesystem locations.
public struct ScribeSessionSummary: Codable, Sendable, Equatable, Identifiable {

  public var id: UUID

  /// Custom session name, or `nil` when the session falls back to its short ID.
  public var name: String?

  public var isPinned: Bool

  public var createdAt: Date

  public var lastMessageAt: Date

  public var workingDirectory: String

  public var profileName: String?

  public var model: String

  /// Name shown in UI lists; matches the persisted metadata fallback.
  public var displayName: String {
    name ?? String(id.uuidString.prefix(8)).uppercased()
  }

  public init(
    id: UUID,
    name: String? = nil,
    isPinned: Bool = false,
    createdAt: Date,
    lastMessageAt: Date,
    workingDirectory: String,
    profileName: String? = nil,
    model: String
  ) {
    self.id = id
    self.name = name
    self.isPinned = isPinned
    self.createdAt = createdAt
    self.lastMessageAt = lastMessageAt
    self.workingDirectory = workingDirectory
    self.profileName = profileName
    self.model = model
  }
}

/// Full presentation state for one open session: summary, persisted messages
/// (including the system message), and the profile catalog needed to render
/// profile controls immediately.
public struct ScribeSessionSnapshot: Codable, Sendable, Equatable {

  public var summary: ScribeSessionSummary

  public var messages: [ScribeMessage]

  public var profileCatalog: [ScribeProfileSummary]

  public init(
    summary: ScribeSessionSummary,
    messages: [ScribeMessage],
    profileCatalog: [ScribeProfileSummary] = []
  ) {
    self.summary = summary
    self.messages = messages
    self.profileCatalog = profileCatalog
  }
}

// MARK: - Requests

public struct ScribeCreateSessionRequest: Sendable, Equatable {

  public var workingDirectory: String

  public var profileName: String?

  public init(workingDirectory: String, profileName: String? = nil) {
    self.workingDirectory = workingDirectory
    self.profileName = profileName
  }
}

public struct ScribeSubmitRequest: Sendable, Equatable {

  public var sessionID: UUID

  public var prompt: String

  public init(sessionID: UUID, prompt: String) {
    self.sessionID = sessionID
    self.prompt = prompt
  }
}

/// Distinguishes "leave the name unchanged" from "clear the name".
public enum ScribeNameUpdate: Codable, Sendable, Equatable {

  case unchanged

  case set(String)

  case cleared
}

public struct ScribePresentationUpdate: Sendable, Equatable {

  public var sessionID: UUID

  public var name: ScribeNameUpdate

  public var isPinned: Bool?

  public init(
    sessionID: UUID,
    name: ScribeNameUpdate = .unchanged,
    isPinned: Bool? = nil
  ) {
    self.sessionID = sessionID
    self.name = name
    self.isPinned = isPinned
  }
}

public struct ScribeReconfigureSessionRequest: Sendable, Equatable {

  public var sessionID: UUID

  public var profileName: String

  public init(sessionID: UUID, profileName: String) {
    self.sessionID = sessionID
    self.profileName = profileName
  }
}

public struct ScribeForkSessionRequest: Sendable, Equatable {

  public var sessionID: UUID

  /// Message index the new session keeps; must be a safe fork boundary.
  public var cutAtMessageIndex: Int

  public init(sessionID: UUID, cutAtMessageIndex: Int) {
    self.sessionID = sessionID
    self.cutAtMessageIndex = cutAtMessageIndex
  }
}

public struct ScribeSummarizeSessionRequest: Sendable, Equatable {

  public var sessionID: UUID

  /// Half-open message range `[startMessageIndex, endMessageIndex)` replaced
  /// by the summary.
  public var startMessageIndex: Int

  public var endMessageIndex: Int

  /// Model used to produce the summary; `nil` uses the session's model.
  public var model: String?

  public init(
    sessionID: UUID,
    startMessageIndex: Int,
    endMessageIndex: Int,
    model: String? = nil
  ) {
    self.sessionID = sessionID
    self.startMessageIndex = startMessageIndex
    self.endMessageIndex = endMessageIndex
    self.model = model
  }
}

// MARK: - Capabilities

/// Features a `ScribeSessionService` supports; the workspace hides controls
/// for unsupported capabilities.
public struct ScribeSessionCapabilities: Codable, Sendable, Equatable {

  public var supportsProfileSwitching: Bool

  public var supportsFork: Bool

  public var supportsTLDR: Bool

  public var supportsDirectorySelection: Bool

  public init(
    supportsProfileSwitching: Bool = true,
    supportsFork: Bool = true,
    supportsTLDR: Bool = true,
    supportsDirectorySelection: Bool = true
  ) {
    self.supportsProfileSwitching = supportsProfileSwitching
    self.supportsFork = supportsFork
    self.supportsTLDR = supportsTLDR
    self.supportsDirectorySelection = supportsDirectorySelection
  }
}

// MARK: - Errors

/// Display-safe service failures. Adapters map underlying errors into these
/// cases before surfacing them through the service contract.
public enum ScribeSessionServiceError: Error, Sendable, Equatable, LocalizedError {

  /// No session exists with the given identifier.
  case notFound(sessionID: UUID)

  /// The session already has an active submission; one turn at a time.
  case busy(sessionID: UUID)

  /// The service does not support the requested feature.
  case unsupported(feature: String)

  /// The request values are invalid (empty prompt, out-of-range indexes, …).
  case invalidRequest(String)

  /// Display-safe failure description for unexpected service errors.
  case failed(String)

  public var errorDescription: String? {
    switch self {
    case .notFound(let id):
      return "Session \(String(id.uuidString.prefix(8)).uppercased()) could not be found."
    case .busy(let id):
      return "Session \(String(id.uuidString.prefix(8)).uppercased()) is already running a turn."
    case .unsupported(let feature):
      return "This service does not support \(feature)."
    case .invalidRequest(let reason):
      return reason
    case .failed(let message):
      return message
    }
  }
}

// MARK: - Service

/// Transport-neutral session service. Implementations own persistence and
/// agent execution; consumers (the shared workspace model) own queueing and
/// presentation state.
public protocol ScribeSessionService: Sendable {

  func capabilities() async -> ScribeSessionCapabilities

  func listSessions() async throws -> [ScribeSessionSummary]

  func listProfiles() async throws -> [ScribeProfileSummary]

  func createSession(_ request: ScribeCreateSessionRequest) async throws
    -> ScribeSessionSnapshot

  func openSession(id: UUID) async throws -> ScribeSessionSnapshot

  func submit(_ request: ScribeSubmitRequest) async throws
    -> AsyncThrowingStream<ScribeSessionEvent, any Error>

  func interrupt(sessionID: UUID) async throws

  func updatePresentation(_ request: ScribePresentationUpdate) async throws
    -> ScribeSessionSummary

  func reconfigure(_ request: ScribeReconfigureSessionRequest) async throws
    -> ScribeSessionSnapshot

  func fork(_ request: ScribeForkSessionRequest) async throws -> ScribeSessionSnapshot

  func summarize(_ request: ScribeSummarizeSessionRequest) async throws
    -> ScribeSessionSnapshot
}
