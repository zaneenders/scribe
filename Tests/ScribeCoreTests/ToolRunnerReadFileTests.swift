import Foundation
import SystemPackage
import Testing

@testable import ScribeCore

@Suite
struct ToolRunnerReadFileTests {
  @Test func returnsUtf8ContentWithMetadata() async throws {
    let registry = ToolRegistry(
      tools: [ShellTool(), ReadFileTool(), WriteFileTool(), EditFileTool()], logger: toolRunnerTestLogger)
    try await withTemporaryDirectory { dir in
      let fileURL = dir.appendingPathComponent("sample.txt")
      let body = "alpha\nβ\n"
      try body.write(to: fileURL, atomically: true, encoding: .utf8)

      let args = try jsonArguments(["path": fileURL.path])
      let json = try! await registry.run(
        name: "read_file", arguments: args, workingDirectory: FilePath("/tmp"), logger: toolRunnerTestLogger,
        abortObserver: AbortNotifier()
      ).text
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
    let registry = ToolRegistry(
      tools: [ShellTool(), ReadFileTool(), WriteFileTool(), EditFileTool()], logger: toolRunnerTestLogger)
    try await withTemporaryDirectory { dir in
      let fileURL = dir.appendingPathComponent("multi.txt")
      let body = (1...10).map { "line\($0)" }.joined(separator: "\n")
      try body.write(to: fileURL, atomically: true, encoding: .utf8)

      let args = try jsonArguments([
        "path": fileURL.path,
        "offset": 4,
        "limit": 3,
      ])
      let json = try! await registry.run(
        name: "read_file", arguments: args, workingDirectory: FilePath("/tmp"), logger: toolRunnerTestLogger,
        abortObserver: AbortNotifier()
      ).text
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
    let registry = ToolRegistry(
      tools: [ShellTool(), ReadFileTool(), WriteFileTool(), EditFileTool()], logger: toolRunnerTestLogger)
    try await withTemporaryDirectory { dir in
      let fileURL = dir.appendingPathComponent("short.txt")
      let body = "only-line"
      try body.write(to: fileURL, atomically: true, encoding: .utf8)

      let args = try jsonArguments(["path": fileURL.path, "offset": 99])
      let json = try! await registry.run(
        name: "read_file", arguments: args, workingDirectory: FilePath("/tmp"), logger: toolRunnerTestLogger,
        abortObserver: AbortNotifier()
      ).text
      let payload = try decodeRead(json)
      #expect(payload.ok == true)
      #expect(payload.content == "")
      #expect(payload.totalLines == 1)
      #expect(payload.truncated == false)
    }
  }

  @Test func limitZeroMeansNoCap() async throws {
    let registry = ToolRegistry(
      tools: [ShellTool(), ReadFileTool(), WriteFileTool(), EditFileTool()], logger: toolRunnerTestLogger)
    try await withTemporaryDirectory { dir in
      let fileURL = dir.appendingPathComponent("all.txt")
      let body = (1...50).map { "L\($0)" }.joined(separator: "\n")
      try body.write(to: fileURL, atomically: true, encoding: .utf8)

      let args = try jsonArguments(["path": fileURL.path, "limit": 0])
      let json = try! await registry.run(
        name: "read_file", arguments: args, workingDirectory: FilePath("/tmp"), logger: toolRunnerTestLogger,
        abortObserver: AbortNotifier()
      ).text
      let payload = try decodeRead(json)
      #expect(payload.ok == true)
      #expect(payload.totalLines == 50)
      #expect(payload.endLine == 50)
      #expect(payload.truncated == false)
    }
  }

  @Test func hardCapsOneVeryLongLineByBytes() async throws {
    let registry = ToolRegistry(
      tools: [ReadFileTool()], logger: toolRunnerTestLogger)
    try await withTemporaryDirectory { dir in
      let fileURL = dir.appendingPathComponent("huge.jsonl")
      let body = String(repeating: "é", count: ReadFileTool.maxContentBytes)
      try body.write(to: fileURL, atomically: true, encoding: .utf8)

      let args = try jsonArguments(["path": fileURL.path, "limit": 0])
      let json = try! await registry.run(
        name: "read_file", arguments: args, workingDirectory: FilePath("/tmp"), logger: toolRunnerTestLogger,
        abortObserver: AbortNotifier()
      ).text
      let payload = try decodeRead(json)

      #expect(payload.content?.utf8.count == ReadFileTool.maxContentBytes)
      #expect(payload.contentCharacters == ReadFileTool.maxContentBytes / 2)
      #expect(payload.maxContentBytes == ReadFileTool.maxContentBytes)
      #expect(payload.truncated == true)
      #expect(payload.truncationReason == "byte_limit")
      #expect(payload.startLine == 1)
      #expect(payload.endLine == 1)
    }
  }

  @Test func hardCapsMultibyteContentByCharacters() async throws {
    let registry = ToolRegistry(
      tools: [ReadFileTool()], logger: toolRunnerTestLogger)
    try await withTemporaryDirectory { dir in
      let fileURL = dir.appendingPathComponent("unicode.txt")
      let body = String(repeating: "é", count: ReadFileTool.maxContentCharacters * 2)
      try body.write(to: fileURL, atomically: true, encoding: .utf8)

      let args = try jsonArguments(["path": fileURL.path, "limit": 0])
      let json = try! await registry.run(
        name: "read_file", arguments: args, workingDirectory: FilePath("/tmp"), logger: toolRunnerTestLogger,
        abortObserver: AbortNotifier()
      ).text
      let payload = try decodeRead(json)

      #expect((payload.content?.utf8.count ?? 0) <= ReadFileTool.maxContentBytes)
      #expect((payload.content?.count ?? 0) <= ReadFileTool.maxContentCharacters)
      #expect(payload.truncated == true)
      #expect(payload.truncationReason == "byte_limit")
    }
  }

  @Test func hardCharacterCapAppliesIndependentlyOfByteCap() async throws {
    let registry = ToolRegistry(
      tools: [ReadFileTool()], logger: toolRunnerTestLogger)
    try await withTemporaryDirectory { dir in
      let fileURL = dir.appendingPathComponent("ascii.txt")
      let body = String(repeating: "a", count: ReadFileTool.maxContentCharacters + 1)
      try body.write(to: fileURL, atomically: true, encoding: .utf8)

      let args = try jsonArguments(["path": fileURL.path, "limit": 0])
      let json = try! await registry.run(
        name: "read_file", arguments: args, workingDirectory: FilePath("/tmp"), logger: toolRunnerTestLogger,
        abortObserver: AbortNotifier()
      ).text
      let payload = try decodeRead(json)

      #expect(payload.content?.count == ReadFileTool.maxContentCharacters)
      #expect(payload.truncationReason == "character_limit")
    }
  }

  @Test func missingFileFails() async throws {
    let registry = ToolRegistry(
      tools: [ShellTool(), ReadFileTool(), WriteFileTool(), EditFileTool()], logger: toolRunnerTestLogger)
    let bogus =
      FileManager.default.temporaryDirectory
      .appendingPathComponent("scribe-no-such-file-\(UUID().uuidString).txt")
    let args = try jsonArguments(["path": bogus.path])
    let json = try! await registry.run(
      name: "read_file", arguments: args, workingDirectory: FilePath("/tmp"), logger: toolRunnerTestLogger,
      abortObserver: AbortNotifier()
    ).text
    let fail = try decodeFail(json)
    #expect(fail.ok == false)
    #expect(fail.error?.contains("path does not exist") == true)
  }

  @Test func missingPathFieldFails() async throws {
    let registry = ToolRegistry(
      tools: [ShellTool(), ReadFileTool(), WriteFileTool(), EditFileTool()], logger: toolRunnerTestLogger)
    let json = try! await registry.run(
      name: "read_file", arguments: "{}", workingDirectory: FilePath("/tmp"), logger: toolRunnerTestLogger,
      abortObserver: AbortNotifier()
    ).text
    let fail = try decodeFail(json)
    #expect(fail.ok == false)
    #expect(fail.error?.contains("missing or empty field path") == true)
  }
}
