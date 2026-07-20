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

    let tmpDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("scribe-capture-test-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: tmpDir) }

    try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)

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

  @Test("create with different IDs produces unique file names")
  func createProducesUniqueNames() throws {
    ShellCaptureDirectory.teardown()

    let tmpDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("scribe-capture-unique-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: tmpDir) }

    try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)

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

  // MARK: - diskSizes

  @Test("diskSizes returns zero for empty files")
  func diskSizesReturnsZeroForEmpty() throws {
    ShellCaptureDirectory.teardown()

    let tmpDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("scribe-capture-size-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: tmpDir) }

    try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)

    let capture = try OutputCapture.create(id: UUID(), in: tmpDir)
    defer { capture.closeHandles() }

    let sizes = capture.diskSizes()
    #expect(sizes.out == 0)
    #expect(sizes.err == 0)
  }

  @Test("diskSizes reflects written data")
  func diskSizesReflectsWrittenData() throws {
    ShellCaptureDirectory.teardown()

    let tmpDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("scribe-capture-size2-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: tmpDir) }

    try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)

    let capture = try OutputCapture.create(id: UUID(), in: tmpDir)
    defer { capture.closeHandles() }

    // Write data directly to the stdout file
    try "Hello, World!".write(to: capture.stdoutURL, atomically: false, encoding: .utf8)

    let sizes = capture.diskSizes()
    #expect(sizes.out > 0)
    #expect(sizes.err == 0)
  }

  // MARK: - closeHandles

  @Test("closeHandles does not crash when called")
  func closeHandlesDoesNotCrash() throws {
    ShellCaptureDirectory.teardown()

    let tmpDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("scribe-capture-close-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: tmpDir) }

    try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)

    let capture = try OutputCapture.create(id: UUID(), in: tmpDir)
    capture.closeHandles()
    // Second close should not crash either
    capture.closeHandles()
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

  @Test("teardown without setup does not crash")
  func teardownWithoutSetup() {
    ShellCaptureDirectory.teardown()
  }

  @Test("double teardown does not crash")
  func doubleTeardownDoesNotCrash() throws {
    let dataHome = FileManager.default.temporaryDirectory
      .appendingPathComponent("scribe-double-teardown-\(UUID().uuidString)")
      .path
    defer { try? FileManager.default.removeItem(atPath: dataHome) }

    try ShellCaptureDirectory.setup(dataHome: dataHome)
    ShellCaptureDirectory.teardown()
    ShellCaptureDirectory.teardown()
  }

  // MARK: - URL to FilePath mapping

  @Test("stdoutURL and stdoutFile point to same path")
  func stdoutURLAndFileConsistent() throws {
    ShellCaptureDirectory.teardown()

    let tmpDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("scribe-capture-consistency-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: tmpDir) }

    try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)

    let capture = try OutputCapture.create(id: UUID(), in: tmpDir)
    defer { capture.closeHandles() }

    #expect(capture.stdoutURL.path == capture.stdoutFile.string)
    #expect(capture.stderrURL.path == capture.stderrFile.string)
  }
}
