import Foundation
import SystemPackage

public struct SessionDocumentSnapshot: Sendable {
  public let sessionId: UUID
  public let directory: FilePath
  public let messages: [ScribeMessage]
  public let safeForkBoundaries: [Int]

  public var count: Int { messages.count }

  public var isEmpty: Bool { messages.isEmpty }

  public subscript(index: Int) -> ScribeMessage { messages[index] }
}
