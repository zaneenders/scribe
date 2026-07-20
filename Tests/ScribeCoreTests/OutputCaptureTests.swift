import Foundation
import SystemPackage
import Testing

@testable import ScribeCore

@Suite(.serialized)
struct OutputCaptureTests {

  // MARK: - create

  @Test("create writes empty files to temp directory")
  func createWritesEmptyFiles() throws {
    // Ensure no leftover session capture dir interferes
    ShellCaptureDirectory.teardown()

    try withTemporaryDirectory { tmpDir in
      let capture = try OutputCapture.create(id: UUID(), in: tmpDir)

      // Files should exist on disk
      #expect(FileManager.default.fileExists(atPath: capture.stdoutFile.string))
      #expect(FileManager.default.fileExists(atPath: capture.stderrFile.string))

      // Files should be empty initially
      let stdoutSize = try FileManager.default.attributesOfItem(atPath: capture.stdoutFile.string)[.size] as? Int
      let stderrSize = try FileManager.default.attributesOfItem(atPath: capture.stderrFile.string)[.size] as? Int
      #expect(stdoutSize == 0)
      #expect(stderrSize == 0)

      capture.closeHandles()
    }
  }

  @Test("create with different IDs produces unique file names")
  func createProducesUniqueNames() throws {
    ShellCaptureDirectory.teardown()

    try withTemporaryDirectory { tmpDir in
      let id1 = UUID()
      let id2 = UUID()

      let c1 = try OutputCapture.create(id: id1, in: tmpDir)
      let c2 = try OutputCapture.create(id: id2, in: tmpDir)
      defer {
        c1.closeHandles()
        c2.closeHandles()
      }

      #expect(c1.stdoutFile != c2.stdoutFile)
      #expect(c1.stderrFile != c2.stderrFile)
      #expect(c1.id == id1)
      #expect(c2.id == id2)
    }
  }

  // MARK: - diskSizes

  @Test("diskSizes returns zero for empty files")
  func diskSizesReturnsZeroForEmpty() throws {
    ShellCaptureDirectory.teardown()

    try withTemporaryDirectory { tmpDir in
      let capture = try OutputCapture.create(id: UUID(), in: tmpDir)
      defer { capture.closeHandles() }

      let sizes = capture.diskSizes()
      #expect(sizes.out == 0)
      #expect(sizes.err == 0)
    }
  }

  @Test("diskSizes reflects written data")
  func diskSizesReflectsWrittenData() throws {
    ShellCaptureDirectory.teardown()

    try withTemporaryDirectory { tmpDir in
      let capture = try OutputCapture.create(id: UUID(), in: tmpDir)
      defer { capture.closeHandles() }

      // Write data directly to the stdout file
      try "Hello, World!".write(to: capture.stdoutURL, atomically: false, encoding: .utf8)

      let sizes = capture.diskSizes()
      #expect(sizes.out > 0)
      #expect(sizes.err == 0)
    }
  }

  // MARK: - Idempotent teardown & reusability

  @Test("setup, teardown twice, setup again — directory removed and component reusable")
  func setupTeardownTwiceAndReusable() throws {
    ShellCaptureDirectory.teardown()

    let dataHome = FileManager.default.temporaryDirectory
      .appendingPathComponent("scribe-reusable-\(UUID().uuidString)")
      .path
    defer { try? FileManager.default.removeItem(atPath: dataHome) }

    // First setup
    try ShellCaptureDirectory.setup(dataHome: dataHome)

    // Verify the per-session capture directory exists
    let shellDir = URL(fileURLWithPath: dataHome)
      .appendingPathComponent("tmp/shell", isDirectory: true)
    let subdirsBefore = try FileManager.default.contentsOfDirectory(
      at: shellDir, includingPropertiesForKeys: nil)
    #expect(!subdirsBefore.isEmpty, "Session capture directory should be created")
    let sessionDir = try #require(subdirsBefore.first)

    // Teardown twice — must be idempotent
    ShellCaptureDirectory.teardown()
    ShellCaptureDirectory.teardown()

    // Per-process directory should be removed
    #expect(
      !FileManager.default.fileExists(atPath: sessionDir.path),
      "Session directory should be removed after teardown")

    // Setup again — component must remain reusable
    try ShellCaptureDirectory.setup(dataHome: dataHome)
    let subdirsAfter = try FileManager.default.contentsOfDirectory(
      at: shellDir, includingPropertiesForKeys: nil)
    #expect(!subdirsAfter.isEmpty, "Should be able to set up again after teardown")
    #expect(subdirsAfter.first != sessionDir, "New session should get a fresh directory")

    ShellCaptureDirectory.teardown()
  }

  @Test("closeHandles is idempotent and files remain on disk")
  func closeHandlesIsIdempotent() throws {
    ShellCaptureDirectory.teardown()

    try withTemporaryDirectory { tmpDir in
      let capture = try OutputCapture.create(id: UUID(), in: tmpDir)

      // Write data before closing
      try "hello".write(to: capture.stdoutURL, atomically: false, encoding: .utf8)

      capture.closeHandles()
      // Second close should not crash
      capture.closeHandles()

      // Files should still exist on disk after close
      #expect(FileManager.default.fileExists(atPath: capture.stdoutFile.string))
      #expect(FileManager.default.fileExists(atPath: capture.stderrFile.string))

      // Written data should still be readable
      let content = try String(contentsOf: capture.stdoutURL, encoding: .utf8)
      #expect(content == "hello")
    }
  }

  // MARK: - Session capture directory lifecycle

  @Test("setupSessionCaptureDir creates directory")
  func setupCreatesDirectory() throws {
    let dataHome = FileManager.default.temporaryDirectory
      .appendingPathComponent("scribe-session-capture-\(UUID().uuidString)")
      .path
    defer {
      ShellCaptureDirectory.teardown()
      try? FileManager.default.removeItem(atPath: dataHome)
    }

    try ShellCaptureDirectory.setup(dataHome: dataHome)

    // The per-session directory should exist somewhere under dataHome/tmp/shell/
    let shellDir = URL(fileURLWithPath: dataHome)
      .appendingPathComponent("tmp", isDirectory: true)
      .appendingPathComponent("shell", isDirectory: true)
    #expect(FileManager.default.fileExists(atPath: shellDir.path))

    // teardown should remove the per-process subdirectory
    ShellCaptureDirectory.teardown()
  }

  @Test("teardown without prior setup does not crash and leaves state clean for subsequent setup")
  func teardownWithoutSetupAllowsSubsequentSetup() throws {
    // Should not crash even when called multiple times with no prior setup
    ShellCaptureDirectory.teardown()
    ShellCaptureDirectory.teardown()

    // State must remain clean for subsequent setup
    let dataHome = FileManager.default.temporaryDirectory
      .appendingPathComponent("scribe-after-teardown-\(UUID().uuidString)")
      .path
    defer {
      ShellCaptureDirectory.teardown()
      try? FileManager.default.removeItem(atPath: dataHome)
    }
    try ShellCaptureDirectory.setup(dataHome: dataHome)

    let shellDir = URL(fileURLWithPath: dataHome)
      .appendingPathComponent("tmp/shell", isDirectory: true)
    let subdirs = try FileManager.default.contentsOfDirectory(
      at: shellDir, includingPropertiesForKeys: nil)
    #expect(!subdirs.isEmpty, "Setup should succeed after teardown-without-setup")
  }

  // MARK: - URL to FilePath mapping

  @Test("stdoutURL and stdoutFile point to same path")
  func stdoutURLAndFileConsistent() throws {
    ShellCaptureDirectory.teardown()

    try withTemporaryDirectory { tmpDir in
      let capture = try OutputCapture.create(id: UUID(), in: tmpDir)
      defer { capture.closeHandles() }

      #expect(capture.stdoutURL.path == capture.stdoutFile.string)
      #expect(capture.stderrURL.path == capture.stderrFile.string)
    }
  }
}
