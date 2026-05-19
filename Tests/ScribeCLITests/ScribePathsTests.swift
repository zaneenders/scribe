import Foundation
import Testing

@testable import ScribeCLI

@Suite
struct ScribePathsTests {
  @Test func logFilePathUsesSessionDirectory() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let paths = ScribePaths(dataHome: root.path)
    let id = UUID()
    let expected =
      root
      .appendingPathComponent("sessions", isDirectory: true)
      .appendingPathComponent(id.uuidString, isDirectory: true)
      .appendingPathComponent("scribe.log", isDirectory: false)
      .path

    #expect(paths.logFilePath(sessionId: id) == expected)
  }
}
