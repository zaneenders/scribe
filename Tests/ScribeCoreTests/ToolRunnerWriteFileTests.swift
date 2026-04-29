import Foundation
import ScribeCore
import Testing

@Suite
struct ToolRunnerWriteFileTests {
  @Test func createsFileWithContent() async throws {
    let runner = ToolRunner()
    try await withTemporaryDirectory { dir in
      let fileURL = dir.appendingPathComponent("out.txt")
      let body = "written_once\nγ\n"
      let args = try jsonArguments(["path": fileURL.path, "content": body])
      let json = await runner.run(name: "write_file", argumentsJSON: args)
      let payload = try decodeWrite(json)
      #expect(payload.ok == true)
      #expect(payload.written == true)

      let onDisk = try String(contentsOf: fileURL, encoding: .utf8)
      #expect(onDisk == body)

      let reread = try decodeRead(
        await runner.run(
          name: "read_file", argumentsJSON: try jsonArguments(["path": fileURL.path])))
      #expect(reread.ok == true)
      #expect(reread.content == body)
    }
  }

  @Test func overwritesExistingFile() async throws {
    let runner = ToolRunner()
    try await withTemporaryDirectory { dir in
      let fileURL = dir.appendingPathComponent("overwrite.txt")
      try "old".write(to: fileURL, atomically: true, encoding: .utf8)
      let args = try jsonArguments(["path": fileURL.path, "content": "new"])
      let json = await runner.run(name: "write_file", argumentsJSON: args)
      let payload = try decodeWrite(json)
      #expect(payload.ok == true)
      let onDisk = try String(contentsOf: fileURL, encoding: .utf8)
      #expect(onDisk == "new")
    }
  }

  @Test func failsWhenParentDirectoryMissing() async throws {
    let runner = ToolRunner()
    let deep =
      FileManager.default.temporaryDirectory
      .appendingPathComponent("scribe-deep-\(UUID().uuidString)/nope/out.txt")
    let args = try jsonArguments(["path": deep.path, "content": "x"])
    let json = await runner.run(name: "write_file", argumentsJSON: args)
    let fail = try decodeFail(json)
    #expect(fail.ok == false)
    #expect(fail.error?.contains("parent directory does not exist") == true)
  }

  @Test func missingContentFieldFails() async throws {
    let runner = ToolRunner()
    try await withTemporaryDirectory { dir in
      let fileURL = dir.appendingPathComponent("only_path.txt")
      let json = await runner.run(
        name: "write_file", argumentsJSON: try jsonArguments(["path": fileURL.path]))
      let fail = try decodeFail(json)
      #expect(fail.ok == false)
      #expect(fail.error?.contains("missing or empty field content") == true)
    }
  }
}
