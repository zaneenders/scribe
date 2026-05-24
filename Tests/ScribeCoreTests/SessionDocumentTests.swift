import Foundation
import Logging
import ScribeCore
import SystemPackage
import Testing

@Suite
struct SessionDocumentTests {

  // MARK: - Helpers

  private static func makeDoc(
    initial: [ScribeMessage] = [],
    persister: any SessionPersister = InMemorySessionPersister()
  ) -> SessionDocument {
    SessionDocument(
      sessionId: UUID(),
      directory: FilePath("/in-memory"),
      initialMessages: initial,
      persister: persister,
      logger: Logger(label: "session-document-test")
    )
  }

  // MARK: - Append

  @Test func appendGrowsRope() async throws {
    let doc = Self.makeDoc(initial: [ScribeMessage(role: .system, content: "sys")])
    let change = try await doc.apply(.append([ScribeMessage(role: .user, content: "hi")]))
    let count = await doc.count
    #expect(count == 2)
    if case .appended(let range) = change {
      #expect(range == 1..<2)
    } else {
      Issue.record("expected .appended")
    }
  }

  @Test func appendEmptyIsNoOp() async throws {
    let doc = Self.makeDoc(initial: [ScribeMessage(role: .system, content: "sys")])
    let change = try await doc.apply(.append([]))
    let count = await doc.count
    #expect(count == 1)
    if case .appended(let range) = change {
      #expect(range == 1..<1)
    }
  }

  // MARK: - Fork

  @Test func forkBecomesNewSession() async throws {
    let initial: [ScribeMessage] = [
      ScribeMessage(role: .system, content: "sys"),
      ScribeMessage(role: .user, content: "q1"),
      ScribeMessage(role: .assistant, content: "a1"),
      ScribeMessage(role: .user, content: "q2"),
    ]
    let doc = Self.makeDoc(initial: initial)
    let originalId = await doc.sessionId
    let newId = UUID()
    let change = try await doc.apply(.fork(cutAt: 2, newSessionId: newId))

    let count = await doc.count
    #expect(count == 2)
    let snap = await doc.snapshot()
    #expect(snap[0].content == "sys")
    #expect(snap[1].content == "q1")

    let newSessionId = await doc.sessionId
    #expect(newSessionId == newId)

    if case .identityChanged(let prev, let now, _, let reason) = change {
      #expect(prev == originalId)
      #expect(now == newId)
      if case .fork = reason {} else { Issue.record("expected .fork reason") }
    } else {
      Issue.record("expected .identityChanged")
    }
  }

  // MARK: - ForkSplice

  @Test func forkSpliceReplacesSlice() async throws {
    let initial: [ScribeMessage] = [
      ScribeMessage(role: .system, content: "sys"),
      ScribeMessage(role: .user, content: "q1"),
      ScribeMessage(role: .assistant, content: "a1"),
      ScribeMessage(role: .user, content: "q2"),
      ScribeMessage(role: .assistant, content: "a2"),
    ]
    let doc = Self.makeDoc(initial: initial)
    let summary = ScribeMessage(role: .assistant, content: "summary")
    _ = try await doc.apply(
      .forkSplice(
        startCut: 1, endCut: 3, replacement: [summary], newSessionId: UUID()))

    let snap = await doc.snapshot()
    #expect(snap.count == 4)
    #expect(snap[0].content == "sys")
    #expect(snap[1].content == "summary")
    #expect(snap[2].content == "q2")
    #expect(snap[3].content == "a2")
  }

  // MARK: - Observation

  @Test func changesStreamReceivesAppend() async throws {
    let doc = Self.makeDoc(initial: [ScribeMessage(role: .system, content: "sys")])
    let stream = await doc.changes()

    let received = Task<ChangeSet?, Never> {
      var iter = stream.makeAsyncIterator()
      return await iter.next()
    }

    _ = try await doc.apply(.append([ScribeMessage(role: .user, content: "hi")]))
    let first = await received.value
    guard let first else {
      Issue.record("expected an event")
      return
    }
    if case .appended(let range) = first {
      #expect(range == 1..<2)
    } else {
      Issue.record("expected .appended, got \(first)")
    }
  }

  // MARK: - Boundaries

  @Test func safeForkBoundariesDelegatesToRope() async throws {
    let doc = Self.makeDoc(initial: [
      ScribeMessage(role: .system, content: "sys"),
      ScribeMessage(role: .user, content: "q"),
    ])
    let b = await doc.safeForkBoundaries()
    #expect(b == [1, 2])
  }
}
