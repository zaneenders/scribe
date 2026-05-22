import Foundation
import SystemPackage
import Testing

@testable import ScribeCLI

@Suite
struct ScribePathsTests {
  @Test func logFileUsesSessionDirectory() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let paths = ScribePaths(dataHome: FilePath(root.path))
    let id = UUID()
    let expected =
      root
      .appendingPathComponent("sessions", isDirectory: true)
      .appendingPathComponent(id.uuidString, isDirectory: true)
      .appendingPathComponent("scribe.log", isDirectory: false)
      .path

    #expect(paths.logFile(sessionId: id).string == expected)
  }
}
