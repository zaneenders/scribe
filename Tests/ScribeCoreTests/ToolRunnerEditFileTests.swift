import Foundation
import Testing

@testable import ScribeCore

@Suite
struct ToolRunnerEditFileTests {
  @Test func replacesUniqueOccurrence() async throws {
    let registry = ToolRegistry(tools: [ShellTool(), ReadFileTool(), WriteFileTool(), EditFileTool()])
    try await withTemporaryDirectory { dir in
      let fileURL = dir.appendingPathComponent("note.txt")
      try "hello world".write(to: fileURL, atomically: true, encoding: .utf8)

      let args = try jsonArguments([
        "path": fileURL.path,
        "old_string": "world",
        "new_string": "scribe",
      ])
      let json = try! await registry.run(
        name: "edit_file", arguments: args, workingDirectory: ScribeFilePath("/tmp"), abortObserver: AbortNotifier())
      let payload = try decodeEdit(json)
      #expect(payload.ok == true)
      #expect(payload.replaced == true)

      let onDisk = try String(contentsOf: fileURL, encoding: .utf8)
      #expect(onDisk == "hello scribe")
    }
  }

  @Test func failsWhenOldStringEmpty() async throws {
    let registry = ToolRegistry(tools: [ShellTool(), ReadFileTool(), WriteFileTool(), EditFileTool()])
    try await withTemporaryDirectory { dir in
      let fileURL = dir.appendingPathComponent("a.txt")
      try "x".write(to: fileURL, atomically: true, encoding: .utf8)

      let args = try jsonArguments([
        "path": fileURL.path,
        "old_string": "",
        "new_string": "y",
      ])
      let json = try! await registry.run(
        name: "edit_file", arguments: args, workingDirectory: ScribeFilePath("/tmp"), abortObserver: AbortNotifier())
      let fail = try decodeFail(json)
      #expect(fail.ok == false)
      #expect(fail.error?.contains("missing or empty field old_string") == true)
    }
  }

  @Test func failsWhenOldStringNotFound() async throws {
    let registry = ToolRegistry(tools: [ShellTool(), ReadFileTool(), WriteFileTool(), EditFileTool()])
    try await withTemporaryDirectory { dir in
      let fileURL = dir.appendingPathComponent("b.txt")
      try "abc".write(to: fileURL, atomically: true, encoding: .utf8)

      let args = try jsonArguments([
        "path": fileURL.path,
        "old_string": "zzz",
        "new_string": "qqq",
      ])
      let json = try! await registry.run(
        name: "edit_file", arguments: args, workingDirectory: ScribeFilePath("/tmp"), abortObserver: AbortNotifier())
      let fail = try decodeFail(json)
      #expect(fail.ok == false)
      #expect(fail.error?.contains("old_string not found") == true)
    }
  }

  @Test func failsWhenOldStringNotUnique() async throws {
    let registry = ToolRegistry(tools: [ShellTool(), ReadFileTool(), WriteFileTool(), EditFileTool()])
    try await withTemporaryDirectory { dir in
      let fileURL = dir.appendingPathComponent("c.txt")
      try "foo foo".write(to: fileURL, atomically: true, encoding: .utf8)

      let args = try jsonArguments([
        "path": fileURL.path,
        "old_string": "foo",
        "new_string": "bar",
      ])
      let json = try! await registry.run(
        name: "edit_file", arguments: args, workingDirectory: ScribeFilePath("/tmp"), abortObserver: AbortNotifier())
      let fail = try decodeFail(json)
      #expect(fail.ok == false)
      #expect(fail.error?.contains("old_string must be unique") == true)
    }
  }

  @Test func missingFileFails() async throws {
    let registry = ToolRegistry(tools: [ShellTool(), ReadFileTool(), WriteFileTool(), EditFileTool()])
    let bogus =
      FileManager.default.temporaryDirectory
      .appendingPathComponent("scribe-edit-missing-\(UUID().uuidString).txt")
    let args = try jsonArguments([
      "path": bogus.path,
      "old_string": "a",
      "new_string": "b",
    ])
    let json = try! await registry.run(
      name: "edit_file", arguments: args, workingDirectory: ScribeFilePath("/tmp"), abortObserver: AbortNotifier())
    let fail = try decodeFail(json)
    #expect(fail.ok == false)
    #expect(fail.error?.contains("path does not exist") == true)
  }
}
