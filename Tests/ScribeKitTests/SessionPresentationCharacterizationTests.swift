import Foundation
import SystemPackage
import Testing

@testable import ScribeKit

@Suite
struct SessionPresentationCharacterizationTests {

  private func makeSession(in directory: URL, isPinned: Bool = false) async throws -> FilePath {
    let path = FilePath(directory.path)
    try await ChatSessionStore.saveMetadata(
      ChatSessionMetadata(
        id: UUID(),
        createdAt: Date(timeIntervalSince1970: 1_700_000_000),
        model: "test-model",
        cwd: "/tmp",
        baseURL: nil,
        scribeVersion: nil,
        lastMessageAt: Date(timeIntervalSince1970: 1_700_000_500),
        name: nil,
        isPinned: isPinned),
      to: path)
    return path
  }

  @Test func renamingTrimsWhitespaceAndPersists() async throws {
    try await withTemporaryDirectory { directory in
      let path = try await makeSession(in: directory)

      let renamed = try await ChatSessionStore.updatePresentation(in: path, name: "  Refactor  ")
      #expect(renamed.name == "Refactor")
      #expect(try ChatSessionStore.loadMetadata(from: path).name == "Refactor")
    }
  }

  @Test func clearingNameRestoresFallbackAndLeavesPinAndRecency() async throws {
    try await withTemporaryDirectory { directory in
      let path = try await makeSession(in: directory, isPinned: true)
      let lastMessageAt = try ChatSessionStore.loadMetadata(from: path).lastMessageAt

      _ = try await ChatSessionStore.updatePresentation(in: path, name: "Named")
      let cleared = try await ChatSessionStore.updatePresentation(in: path, name: "   ")

      #expect(cleared.name == nil)
      #expect(cleared.displayName == String(cleared.id.uuidString.prefix(8)).uppercased())
      #expect(cleared.isPinned)
      #expect(cleared.lastMessageAt == lastMessageAt)
      #expect(try ChatSessionStore.loadMetadata(from: path).name == nil)
    }
  }

  @Test func pinTogglePreservesNameAndRecency() async throws {
    try await withTemporaryDirectory { directory in
      let path = try await makeSession(in: directory)
      _ = try await ChatSessionStore.updatePresentation(in: path, name: "Named")
      let lastMessageAt = try ChatSessionStore.loadMetadata(from: path).lastMessageAt

      let pinned = try await ChatSessionStore.updatePresentation(in: path, isPinned: true)
      #expect(pinned.isPinned)
      #expect(pinned.name == "Named")
      #expect(pinned.lastMessageAt == lastMessageAt)

      let unpinned = try await ChatSessionStore.updatePresentation(in: path, isPinned: false)
      #expect(!unpinned.isPinned)
      #expect(unpinned.name == "Named")
    }
  }

  @Test func presentationUpdateWithNoFieldsLeavesMetadataUnchanged() async throws {
    try await withTemporaryDirectory { directory in
      let path = try await makeSession(in: directory, isPinned: true)
      _ = try await ChatSessionStore.updatePresentation(in: path, name: "Named")
      let before = try ChatSessionStore.loadMetadata(from: path)

      let after = try await ChatSessionStore.updatePresentation(in: path)

      #expect(after.name == before.name)
      #expect(after.isPinned == before.isPinned)
      #expect(after.lastMessageAt == before.lastMessageAt)
    }
  }

  @Test func updateConfigurationPreservesNameAndPin() async throws {
    try await withTemporaryDirectory { directory in
      let path = try await makeSession(in: directory, isPinned: true)
      _ = try await ChatSessionStore.updatePresentation(in: path, name: "Named")

      let updated = try await ChatSessionStore.updateConfiguration(
        in: path,
        model: "new-model",
        profileName: "economy",
        baseURL: "https://new.example")

      #expect(updated.model == "new-model")
      #expect(updated.profileName == "economy")
      #expect(updated.baseURL == "https://new.example")
      #expect(updated.name == "Named")
      #expect(updated.isPinned)
    }
  }
}
