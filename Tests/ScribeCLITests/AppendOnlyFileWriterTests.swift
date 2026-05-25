import Foundation
import SystemPackage
import Testing

@testable import ScribeCLI

@Suite
struct AppendOnlyFileWriterTests {
  @Test func createsFileAndAppends() throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
      .appendingPathComponent("out.jsonl", isDirectory: false)
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

    let writer = try AppendOnlyFileWriter(filePath: FilePath(url.path))
    try writer.append(Data("line1\n".utf8))
    try writer.append(Data("line2\n".utf8))
    writer.close()

    let text = try String(contentsOf: url, encoding: .utf8)
    #expect(text == "line1\nline2\n")
  }

  @Test func resumesAtEndOfExistingFile() throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
      .appendingPathComponent("resume.jsonl", isDirectory: false)
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try Data("existing\n".utf8).write(to: url)

    let writer = try AppendOnlyFileWriter(filePath: FilePath(url.path))
    try writer.append(Data("new\n".utf8))
    writer.close()

    let text = try String(contentsOf: url, encoding: .utf8)
    #expect(text == "existing\nnew\n")
  }
}
