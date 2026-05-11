import Foundation
import Testing

@testable import ScribeCLI

/// Tests that manipulate SCRIBE_HOME must run serially since the env var is process-wide.
@Suite(.serialized)
struct ScribePathsTests {
  @Test
  func defaultDataHome() {
    unsetenv("SCRIBE_HOME")
    let paths = ScribePaths.resolve()
    #expect(paths.dataHome.hasSuffix("/.scribe"))
    #expect(paths.defaultConfigPath.hasSuffix("/scribe-config.json"))
    #expect(paths.logDirectoryPath.hasSuffix("/logs"))
    #expect(paths.sessionsDirectoryPath.hasSuffix("/sessions"))
  }

  @Test
  func customSCRIBE_HOME() {
    let tmp = FileManager.default.temporaryDirectory
      .appendingPathComponent("scribe-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: tmp) }
    try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

    setenv("SCRIBE_HOME", tmp.path, 1)
    defer { unsetenv("SCRIBE_HOME") }

    let paths = ScribePaths.resolve()

    #expect(paths.dataHome == tmp.path)
    #expect(
      paths.defaultConfigPath
        == tmp.appendingPathComponent("scribe-config.json").path)
    #expect(
      paths.logDirectoryPath == tmp.appendingPathComponent("logs").path)
    #expect(
      paths.sessionsDirectoryPath == tmp.appendingPathComponent("sessions").path)
  }

  @Test
  func emptySCRIBE_HOME_fallsBackToDefault() {
    setenv("SCRIBE_HOME", "", 1)
    defer { unsetenv("SCRIBE_HOME") }

    let paths = ScribePaths.resolve()
    #expect(paths.dataHome.hasSuffix("/.scribe"))
  }

  @Test
  func explicitInitProducesCorrectSubpaths() {
    let paths = ScribePaths(dataHome: "/tmp/scribe-test")
    #expect(paths.dataHome == "/tmp/scribe-test")
    #expect(paths.defaultConfigPath == "/tmp/scribe-test/scribe-config.json")
    #expect(paths.logDirectoryPath == "/tmp/scribe-test/logs")
    #expect(paths.sessionsDirectoryPath == "/tmp/scribe-test/sessions")
  }

  @Test
  func tildeExpansionInSCRIBE_HOME() {
    let testDir = "~/.scribe-test-\(UUID().uuidString)"
    setenv("SCRIBE_HOME", testDir, 1)
    defer { unsetenv("SCRIBE_HOME") }

    let paths = ScribePaths.resolve()
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    // Should not contain literal tilde.
    #expect(!paths.dataHome.contains("~"))
    #expect(paths.dataHome.hasPrefix(home))
  }
}
