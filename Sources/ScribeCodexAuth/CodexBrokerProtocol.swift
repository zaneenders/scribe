import Foundation

public struct CodexConnectionReceipt: Codable, Equatable, Sendable {
  public let handoffID: UUID
  public let connectionID: UUID
  public let accountID: String
  public let generation: Int
  public init(handoffID: UUID, connectionID: UUID, accountID: String, generation: Int) {
    self.handoffID = handoffID; self.connectionID = connectionID
    self.accountID = accountID; self.generation = generation
  }
}

public struct CodexHandoffRequest: Codable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
  public let handoffID: UUID
  public let expectedGeneration: Int
  public let credential: CodexCredential
  public var description: String { "CodexHandoffRequest(<redacted>)" }
  public var debugDescription: String { description }
  public init(handoffID: UUID, expectedGeneration: Int, credential: CodexCredential) {
    self.handoffID = handoffID; self.expectedGeneration = expectedGeneration; self.credential = credential
  }
}

public struct CodexConnectionStatus: Codable, Sendable {
  public let generation: Int
  public let connection: CodexConnectionReceipt?
  public let receipts: [CodexConnectionReceipt]
  public let recoveryRequired: Bool
  public init(generation: Int, connection: CodexConnectionReceipt?, receipts: [CodexConnectionReceipt], recoveryRequired: Bool) {
    self.generation = generation; self.connection = connection
    self.receipts = receipts; self.recoveryRequired = recoveryRequired
  }
}

public struct CodexAccessRequest: Codable, Sendable {
  public let connectionID: UUID
  public let generation: Int
  public let rejectedLease: String?
  public init(connectionID: UUID, generation: Int, rejectedLease: String? = nil) {
    self.connectionID = connectionID; self.generation = generation; self.rejectedLease = rejectedLease
  }
}

public enum CodexStrictJSON {
  public static func decode<T: Decodable>(_ type: T.Type, from data: Data, fields: Set<String>, nested: [String: Set<String>] = [:]) throws -> T {
    guard data.count <= 32_768,
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      Set(object.keys).isSubset(of: fields) else { throw CodexAuthorityError.conflict }
    for (key, allowed) in nested {
      guard let child = object[key] as? [String: Any], Set(child.keys).isSubset(of: allowed) else {
        throw CodexAuthorityError.conflict
      }
    }
    do { return try JSONDecoder().decode(type, from: data) }
    catch { throw CodexAuthorityError.conflict }
  }
}
