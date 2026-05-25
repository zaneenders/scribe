import Foundation
import SystemPackage

/// Sendable read snapshot of a ``SessionDocument`` for UI and picker use.
///
/// Built by ``SessionHarness/snapshot()`` so embedders on other isolation
/// domains can render or fork without borrowing the noncopyable doc.
public struct SessionDocumentSnapshot: Sendable {
  public let sessionId: UUID
  public let directory: FilePath
  public let messages: [ScribeMessage]
  public let safeForkBoundaries: [Int]

  public var count: Int { messages.count }

  public var isEmpty: Bool { messages.isEmpty }

  public subscript(index: Int) -> ScribeMessage { messages[index] }
}
