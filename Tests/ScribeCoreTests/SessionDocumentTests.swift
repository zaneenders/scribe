import Foundation
import Logging
import ScribeCore
import SystemPackage
import Testing

@Suite
struct SessionDocumentTests {


  private static func makeDoc(
    seed: [ScribeMessage] = []
  ) -> SessionDocument {
    var doc = SessionDocument(
      sessionId: UUID(),
      directory: FilePath("/in-memory"),
      logger: Logger(label: "session-document-test")
    )
    if !seed.isEmpty {
      doc.append(seed)
    }
    return doc
  }


  @Test func subscriptReadsMessages() {
    let doc = Self.makeDoc(seed: [
      ScribeMessage(role: .system, content: "sys"),
      ScribeMessage(role: .user, content: "hi"),
    ])
    #expect(doc.count == 2)
    #expect(doc[0].content == "sys")
    #expect(doc[1].content == "hi")
  }


  @Test func appendGrowsRope() {
    var doc = Self.makeDoc(seed: [ScribeMessage(role: .system, content: "sys")])
    let range = doc.append([ScribeMessage(role: .user, content: "hi")])
    #expect(doc.count == 2)
    #expect(range == 1..<2)
    #expect(doc[1].content == "hi")
  }

  @Test func appendEmptyIsNoOp() {
    var doc = Self.makeDoc(seed: [ScribeMessage(role: .system, content: "sys")])
    let range = doc.append([])
    #expect(doc.count == 1)
    #expect(range == 1..<1)
  }

  @Test func emptyInitStartsWithZeroMessages() {
    var doc = SessionDocument(
      sessionId: UUID(),
      directory: FilePath("/in-memory"),
      logger: Logger(label: "session-document-test")
    )
    #expect(doc.count == 0)
    _ = doc.append([ScribeMessage(role: .system, content: "seed")])
    #expect(doc.count == 1)
  }


  @Test func successorForkBecomesNewSession() {
    let initial: [ScribeMessage] = [
      ScribeMessage(role: .system, content: "sys"),
      ScribeMessage(role: .user, content: "q1"),
      ScribeMessage(role: .assistant, content: "a1"),
      ScribeMessage(role: .user, content: "q2"),
    ]
    var doc = Self.makeDoc(seed: initial)
    let originalId = doc.sessionId
    let newId = UUID()
    let newDir = FilePath("/in-memory/\(newId.uuidString)")
    let successor = doc.successor(
      splicing: 2..<doc.count,
      newSessionId: newId,
      newDirectory: newDir
    )
    doc = successor

    #expect(doc.count == 2)
    #expect(doc[0].content == "sys")
    #expect(doc[1].content == "q1")
    #expect(doc.sessionId == newId)
    #expect(doc.directory == newDir)
    #expect(doc.sessionId != originalId)
  }


  @Test func successorSplicesReplacement() {
    let initial: [ScribeMessage] = [
      ScribeMessage(role: .system, content: "sys"),
      ScribeMessage(role: .user, content: "q1"),
      ScribeMessage(role: .assistant, content: "a1"),
      ScribeMessage(role: .user, content: "q2"),
      ScribeMessage(role: .assistant, content: "a2"),
    ]
    var doc = Self.makeDoc(seed: initial)
    let summary = ScribeMessage(role: .assistant, content: "summary")
    let newId = UUID()
    let newDir = FilePath("/in-memory/\(newId.uuidString)")
    let successor = doc.successor(
      splicing: 1..<3,
      inserting: [summary],
      newSessionId: newId,
      newDirectory: newDir
    )
    doc = successor

    #expect(doc.count == 4)
    #expect(doc[0].content == "sys")
    #expect(doc[1].content == "summary")
    #expect(doc[2].content == "q2")
    #expect(doc[3].content == "a2")
  }


  @Test func chatMessagesConvertsToWire() {
    let doc = Self.makeDoc(seed: [
      ScribeMessage(role: .system, content: "sys"),
      ScribeMessage(role: .user, content: "hi"),
    ])
    let wire = doc.chatMessages()
    #expect(wire.count == 2)
    #expect(wire[0].role == .system)
    #expect(wire[1].role == .user)
    if case .case1(let text) = wire[1].content {
      #expect(text == "hi")
    } else {
      Issue.record("Expected string content on wire message")
    }
  }


  @Test func safeForkBoundariesDelegatesToRope() {
    let doc = Self.makeDoc(seed: [
      ScribeMessage(role: .system, content: "sys"),
      ScribeMessage(role: .user, content: "q"),
    ])
    let b = doc.safeForkBoundaries()
    #expect(b == [1, 2])
  }
}
