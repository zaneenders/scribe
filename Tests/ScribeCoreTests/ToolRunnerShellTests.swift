import Foundation
import ScribeCore
import Testing

@Suite
struct ToolRunnerShellTests {
  @Test func echoProducesStdout() async throws {
    let runner = ToolRunner()
    let args = try jsonArguments(["command": "/bin/echo scribetest"])
    let json = await runner.run(name: "shell", argumentsJSON: args)
    let out = try decodeShell(json)
    #expect(out.ok == true)
    #expect(out.exitCode == 0)
    #expect(out.stderr == "")
    #expect(out.stdout?.trimmingCharacters(in: .newlines) == "scribetest")
  }

  @Test func honorsWorkingDirectory() async throws {
    let runner = ToolRunner()
    try await withTemporaryDirectory { dir in
      let marker = dir.appendingPathComponent("only_here.txt")
      try "cwd_ok".write(to: marker, atomically: true, encoding: .utf8)

      let args = try jsonArguments(["command": "/bin/cat only_here.txt", "cwd": dir.path])
      let json = await runner.run(name: "shell", argumentsJSON: args)
      let out = try decodeShell(json)
      #expect(out.ok == true)
      #expect(out.exitCode == 0)
      #expect(out.stderr == "")
      #expect(out.stdout == "cwd_ok")
    }
  }

  @Test func reportsNonZeroExitWithoutOkFalse() async throws {
    let runner = ToolRunner()
    let args = try jsonArguments(["command": "/bin/sh -c 'exit 7'"])
    let json = await runner.run(name: "shell", argumentsJSON: args)
    let out = try decodeShell(json)
    #expect(out.ok == true)
    #expect(out.exitCode == 7)
  }

  @Test func emptyCommandFails() async throws {
    let runner = ToolRunner()
    let args = try jsonArguments(["command": "   "])
    let json = await runner.run(name: "shell", argumentsJSON: args)
    let fail = try decodeFail(json)
    #expect(fail.ok == false)
    #expect(fail.error?.contains("command is empty") == true)
  }

  @Test func invalidWorkingDirectoryFails() async throws {
    let runner = ToolRunner()
    let bogusDir =
      FileManager.default.temporaryDirectory
      .appendingPathComponent("scribe-no-such-cwd-\(UUID().uuidString)", isDirectory: true)
    let args = try jsonArguments(["command": "/bin/true", "cwd": bogusDir.path])
    let json = await runner.run(name: "shell", argumentsJSON: args)
    let fail = try decodeFail(json)
    #expect(fail.ok == false)
    #expect(fail.error?.contains("path does not exist") == true)
  }
}
