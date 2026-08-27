import Foundation
import SystemPackage
import Testing

@testable import ScribeCLI
@testable import ScribeKit

@Suite
struct AppendOnlyFileWriterTests {
  @Test func createsFileAndAppends() throws {
    try withTemporaryDirectory { dir in
      let url = dir.appendingPathComponent("out.jsonl", isDirectory: false)

      let writer = try AppendOnlyFileWriter(filePath: FilePath(url.path))
      try writer.append(Data("line1\n".utf8))
      try writer.append(Data("line2\n".utf8))
      writer.close()

      let text = try String(contentsOf: url, encoding: .utf8)
      #expect(text == "line1\nline2\n")
    }
  }

  @Test func resumesAtEndOfExistingFile() throws {
    try withTemporaryDirectory { dir in
      let url = dir.appendingPathComponent("resume.jsonl", isDirectory: false)
      try Data("existing\n".utf8).write(to: url)

      let writer = try AppendOnlyFileWriter(filePath: FilePath(url.path))
      try writer.append(Data("new\n".utf8))
      writer.close()

      let text = try String(contentsOf: url, encoding: .utf8)
      #expect(text == "existing\nnew\n")
    }
  }
}
