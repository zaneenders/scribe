import Foundation
import ScribeCore
import Testing

@Suite
struct ToolRunnerReadFileTests {
  @Test func returnsUtf8ContentWithMetadata() async throws {
    let runner = ToolRunner()
    try await withTemporaryDirectory { dir in
      let fileURL = dir.appendingPathComponent("sample.txt")
      // Trailing newline produces 3 split parts (alpha, β, "") under
      // omittingEmptySubsequences:false — same convention as `wc`.
      let body = "alpha\nβ\n"
      try body.write(to: fileURL, atomically: true, encoding: .utf8)

      let args = try jsonArguments(["path": fileURL.path])
      let json = await runner.run(name: "read_file", argumentsJSON: args)
      let payload = try decodeRead(json)
      #expect(payload.ok == true)
      #expect(payload.content == body)
      #expect(payload.bytes == body.utf8.count)
      #expect(payload.totalLines == 3)
      #expect(payload.startLine == 1)
      #expect(payload.endLine == 3)
      #expect(payload.truncated == false)
      #expect(payload.path?.hasSuffix("sample.txt") == true)
    }
  }

  @Test func returnsRequestedSliceWithOffsetAndLimit() async throws {
    let runner = ToolRunner()
    try await withTemporaryDirectory { dir in
      let fileURL = dir.appendingPathComponent("multi.txt")
      let body = (1...10).map { "line\($0)" }.joined(separator: "\n")
      try body.write(to: fileURL, atomically: true, encoding: .utf8)

      let args = try jsonArguments([
        "path": fileURL.path,
        "offset": 4,
        "limit": 3,
      ])
      let json = await runner.run(name: "read_file", argumentsJSON: args)
      let payload = try decodeRead(json)
      #expect(payload.ok == true)
      #expect(payload.content == "line4\nline5\nline6")
      #expect(payload.startLine == 4)
      #expect(payload.endLine == 6)
      #expect(payload.totalLines == 10)
      #expect(payload.truncated == true)
    }
  }

  @Test func returnsEmptyContentWhenOffsetPastEnd() async throws {
    let runner = ToolRunner()
    try await withTemporaryDirectory { dir in
      let fileURL = dir.appendingPathComponent("short.txt")
      let body = "only-line"
      try body.write(to: fileURL, atomically: true, encoding: .utf8)

      let args = try jsonArguments(["path": fileURL.path, "offset": 99])
      let json = await runner.run(name: "read_file", argumentsJSON: args)
      let payload = try decodeRead(json)
      #expect(payload.ok == true)
      #expect(payload.content == "")
      #expect(payload.totalLines == 1)
      #expect(payload.truncated == false)
    }
  }

  @Test func limitZeroMeansNoCap() async throws {
    let runner = ToolRunner()
    try await withTemporaryDirectory { dir in
      let fileURL = dir.appendingPathComponent("all.txt")
      let body = (1...50).map { "L\($0)" }.joined(separator: "\n")
      try body.write(to: fileURL, atomically: true, encoding: .utf8)

      let args = try jsonArguments(["path": fileURL.path, "limit": 0])
      let json = await runner.run(name: "read_file", argumentsJSON: args)
      let payload = try decodeRead(json)
      #expect(payload.ok == true)
      #expect(payload.totalLines == 50)
      #expect(payload.endLine == 50)
      #expect(payload.truncated == false)
    }
  }

  @Test func missingFileFails() async throws {
    let runner = ToolRunner()
    let bogus =
      FileManager.default.temporaryDirectory
      .appendingPathComponent("scribe-no-such-file-\(UUID().uuidString).txt")
    let args = try jsonArguments(["path": bogus.path])
    let json = await runner.run(name: "read_file", argumentsJSON: args)
    let fail = try decodeFail(json)
    #expect(fail.ok == false)
    #expect(fail.error?.contains("path does not exist") == true)
  }

  @Test func missingPathFieldFails() async throws {
    let runner = ToolRunner()
    let json = await runner.run(name: "read_file", argumentsJSON: "{}")
    let fail = try decodeFail(json)
    #expect(fail.ok == false)
    #expect(fail.error?.contains("missing or empty field path") == true)
  }
}
