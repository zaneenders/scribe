import Foundation
import Logging
import ScribeCore
import SystemPackage
import Testing

@Suite
struct SessionDocumentTests {

  // MARK: - Helpers

  private static func makeDoc(
    initial: [ScribeMessage] = []
  ) -> SessionDocument {
    SessionDocument(
      sessionId: UUID(),
      directory: FilePath("/in-memory"),
      initialMessages: initial,
      logger: Logger(label: "session-document-test")
    )
  }

  // MARK: - Append

  @Test func appendGrowsRope() {
    var doc = Self.makeDoc(initial: [ScribeMessage(role: .system, content: "sys")])
    let change = doc.append([ScribeMessage(role: .user, content: "hi")])
    #expect(doc.count == 2)
    if case .appended(let range) = change {
      #expect(range == 1..<2)
    } else {
      Issue.record("expected .appended")
    }
  }

  @Test func appendEmptyIsNoOp() {
    var doc = Self.makeDoc(initial: [ScribeMessage(role: .system, content: "sys")])
    let change = doc.append([])
    #expect(doc.count == 1)
    if case .appended(let range) = change {
      #expect(range == 1..<1)
    }
  }

  // MARK: - Swap identity (fork)

  @Test func swapIdentityBecomesNewSession() {
    let initial: [ScribeMessage] = [
      ScribeMessage(role: .system, content: "sys"),
      ScribeMessage(role: .user, content: "q1"),
      ScribeMessage(role: .assistant, content: "a1"),
      ScribeMessage(role: .user, content: "q2"),
    ]
    var doc = Self.makeDoc(initial: initial)
    let originalId = doc.sessionId
    let newId = UUID()
    let newDir = FilePath("/in-memory/\(newId.uuidString)")
    let change = doc.swapIdentity(
      cutAt: 2,
      tail: [],
      newSessionId: newId,
      newDirectory: newDir,
      reason: .fork
    )

    #expect(doc.count == 2)
    let snap = doc.snapshot()
    #expect(snap[0].content == "sys")
    #expect(snap[1].content == "q1")
    #expect(doc.sessionId == newId)
    #expect(doc.directory == newDir)

    if case .identityChanged(let prev, let now, let dir, let reason) = change {
      #expect(prev == originalId)
      #expect(now == newId)
      #expect(dir == newDir)
      if case .fork = reason {} else { Issue.record("expected .fork reason") }
    } else {
      Issue.record("expected .identityChanged")
    }
  }

  // MARK: - Swap identity (tldr / splice)

  @Test func swapIdentitySplicesReplacement() {
    let initial: [ScribeMessage] = [
      ScribeMessage(role: .system, content: "sys"),
      ScribeMessage(role: .user, content: "q1"),
      ScribeMessage(role: .assistant, content: "a1"),
      ScribeMessage(role: .user, content: "q2"),
      ScribeMessage(role: .assistant, content: "a2"),
    ]
    var doc = Self.makeDoc(initial: initial)
    let summary = ScribeMessage(role: .assistant, content: "summary")
    // forkSplice semantics: prefix(1) + [summary] + suffix(3...) =
    // [sys, summary, q2, a2]. The host computes the tail; the doc just
    // takes the prefix cut and the precomputed tail.
    let suffix = Array(doc.snapshot()[3..<5])
    let tail = [summary] + suffix
    let newId = UUID()
    let newDir = FilePath("/in-memory/\(newId.uuidString)")
    _ = doc.swapIdentity(
      cutAt: 1,
      tail: tail,
      newSessionId: newId,
      newDirectory: newDir,
      reason: .forkSplice
    )

    let snap = doc.snapshot()
    #expect(snap.count == 4)
    #expect(snap[0].content == "sys")
    #expect(snap[1].content == "summary")
    #expect(snap[2].content == "q2")
    #expect(snap[3].content == "a2")
  }

  // MARK: - Boundaries

  @Test func safeForkBoundariesDelegatesToRope() {
    let doc = Self.makeDoc(initial: [
      ScribeMessage(role: .system, content: "sys"),
      ScribeMessage(role: .user, content: "q"),
    ])
    let b = doc.safeForkBoundaries()
    #expect(b == [1, 2])
  }
}
