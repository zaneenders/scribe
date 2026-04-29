import Foundation
import ScribeCore
import Testing

@Suite
struct ToolRunnerEditFileTests {
  @Test func replacesUniqueOccurrence() async throws {
    let runner = ToolRunner()
    try await withTemporaryDirectory { dir in
      let fileURL = dir.appendingPathComponent("note.txt")
      try "hello world".write(to: fileURL, atomically: true, encoding: .utf8)

      let args = try jsonArguments([
        "path": fileURL.path,
        "old_string": "world",
        "new_string": "scribe",
      ])
      let json = await runner.run(name: "edit_file", argumentsJSON: args)
      let payload = try decodeEdit(json)
      #expect(payload.ok == true)
      #expect(payload.replaced == true)
      #expect(payload.content == "hello scribe")

      let onDisk = try String(contentsOf: fileURL, encoding: .utf8)
      #expect(onDisk == "hello scribe")
    }
  }

  @Test func failsWhenOldStringEmpty() async throws {
    let runner = ToolRunner()
    try await withTemporaryDirectory { dir in
      let fileURL = dir.appendingPathComponent("a.txt")
      try "x".write(to: fileURL, atomically: true, encoding: .utf8)

      let args = try jsonArguments([
        "path": fileURL.path,
        "old_string": "",
        "new_string": "y",
      ])
      let json = await runner.run(name: "edit_file", argumentsJSON: args)
      let fail = try decodeFail(json)
      #expect(fail.ok == false)
      #expect(fail.error?.contains("missing or empty field old_string") == true)
    }
  }

  @Test func failsWhenOldStringNotFound() async throws {
    let runner = ToolRunner()
    try await withTemporaryDirectory { dir in
      let fileURL = dir.appendingPathComponent("b.txt")
      try "abc".write(to: fileURL, atomically: true, encoding: .utf8)

      let args = try jsonArguments([
        "path": fileURL.path,
        "old_string": "zzz",
        "new_string": "qqq",
      ])
      let json = await runner.run(name: "edit_file", argumentsJSON: args)
      let fail = try decodeFail(json)
      #expect(fail.ok == false)
      #expect(fail.error?.contains("old_string not found") == true)
    }
  }

  @Test func failsWhenOldStringNotUnique() async throws {
    let runner = ToolRunner()
    try await withTemporaryDirectory { dir in
      let fileURL = dir.appendingPathComponent("c.txt")
      try "foo foo".write(to: fileURL, atomically: true, encoding: .utf8)

      let args = try jsonArguments([
        "path": fileURL.path,
        "old_string": "foo",
        "new_string": "bar",
      ])
      let json = await runner.run(name: "edit_file", argumentsJSON: args)
      let fail = try decodeFail(json)
      #expect(fail.ok == false)
      #expect(fail.error?.contains("old_string must be unique") == true)
    }
  }

  @Test func missingFileFails() async throws {
    let runner = ToolRunner()
    let bogus =
      FileManager.default.temporaryDirectory
      .appendingPathComponent("scribe-edit-missing-\(UUID().uuidString).txt")
    let args = try jsonArguments([
      "path": bogus.path,
      "old_string": "a",
      "new_string": "b",
    ])
    let json = await runner.run(name: "edit_file", argumentsJSON: args)
    let fail = try decodeFail(json)
    #expect(fail.ok == false)
    #expect(fail.error?.contains("path does not exist") == true)
  }
}
