import Foundation
import SystemPackage
import Testing

@testable import ScribeCLI

@Suite
struct ScribePathsTests {
  @Test func logFileUsesSessionDirectory() throws {
    try withTemporaryDirectory { root in
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
}
