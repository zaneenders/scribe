import Foundation
import ScribeCore
import Testing

@Suite
struct ToolRunnerReadFileTests {
  @Test func returnsUtf8Content() async throws {
    let runner = ToolRunner()
    try await withTemporaryDirectory { dir in
      let fileURL = dir.appendingPathComponent("sample.txt")
      let body = "alpha\nβ\n"
      try body.write(to: fileURL, atomically: true, encoding: .utf8)

      let args = try jsonArguments(["path": fileURL.path])
      let json = await runner.run(name: "read_file", argumentsJSON: args)
      let payload = try decodeRead(json)
      #expect(payload.ok == true)
      #expect(payload.content == body)
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
