import Foundation
import ScribeCore

public struct ScribeSessionSummary: Codable, Sendable, Equatable, Identifiable {

  public var id: UUID

  public var name: String?

  public var isPinned: Bool

  public var createdAt: Date

  public var lastMessageAt: Date

  public var workingDirectory: String

  public var profileName: String?

  public var model: String

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

public struct ScribeSessionSnapshot: Codable, Sendable, Equatable {

  public var summary: ScribeSessionSummary

  public var messages: [ScribeMessage]

  public var profileCatalog: [ScribeProfileSummary]

  public var reasoningEffort: String?

  public var serviceTier: String?

  public init(
    summary: ScribeSessionSummary,
    messages: [ScribeMessage],
    profileCatalog: [ScribeProfileSummary] = [],
    reasoningEffort: String? = nil,
    serviceTier: String? = nil
  ) {
    self.summary = summary
    self.messages = messages
    self.profileCatalog = profileCatalog
    self.reasoningEffort = reasoningEffort
    self.serviceTier = serviceTier
  }
}

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

  public var reasoningEffort: String?

  public var serviceTier: String?

  public init(
    sessionID: UUID, profileName: String, reasoningEffort: String? = nil,
    serviceTier: String? = nil
  ) {
    self.sessionID = sessionID
    self.profileName = profileName
    self.reasoningEffort = reasoningEffort
    self.serviceTier = serviceTier
  }
}

public struct ScribeForkSessionRequest: Sendable, Equatable {

  public var sessionID: UUID

  public var cutAtMessageIndex: Int

  public init(sessionID: UUID, cutAtMessageIndex: Int) {
    self.sessionID = sessionID
    self.cutAtMessageIndex = cutAtMessageIndex
  }
}

public struct ScribeSummarizeSessionRequest: Sendable, Equatable {

  public var sessionID: UUID

  public var startMessageIndex: Int

  public var endMessageIndex: Int

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

public enum ScribeSessionServiceError: Error, Sendable, Equatable, LocalizedError {

  case notFound(sessionID: UUID)

  case busy(sessionID: UUID)

  case unsupported(feature: String)

  case invalidRequest(String)

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
