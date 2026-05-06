import Foundation
import ScribeCore
import Testing

@Suite
struct ToolRunnerShellTests {
  @Test func echoProducesStdout() async throws {
    let registry = ToolRegistry(tools: [ShellTool(), ReadFileTool(), WriteFileTool(), EditFileTool()])
    let args = try jsonArguments(["command": "/bin/echo scribetest"])
    let json = await registry.run(name: "shell", arguments: args)
    let out = try decodeShell(json)
    #expect(out.ok == true)
    #expect(out.exitCode == 0)
    #expect(out.stderr == "")
    #expect(out.stdout?.trimmingCharacters(in: .newlines) == "scribetest")
  }

  @Test func honorsWorkingDirectory() async throws {
    let registry = ToolRegistry(tools: [ShellTool(), ReadFileTool(), WriteFileTool(), EditFileTool()])
    try await withTemporaryDirectory { dir in
      let marker = dir.appendingPathComponent("only_here.txt")
      try "cwd_ok".write(to: marker, atomically: true, encoding: .utf8)

      let args = try jsonArguments(["command": "/bin/cat only_here.txt", "cwd": dir.path])
      let json = await registry.run(name: "shell", arguments: args)
      let out = try decodeShell(json)
      #expect(out.ok == true)
      #expect(out.exitCode == 0)
      #expect(out.stderr == "")
      #expect(out.stdout == "cwd_ok")
    }
  }

  @Test func reportsNonZeroExitWithoutOkFalse() async throws {
    let registry = ToolRegistry(tools: [ShellTool(), ReadFileTool(), WriteFileTool(), EditFileTool()])
    let args = try jsonArguments(["command": "/bin/sh -c 'exit 7'"])
    let json = await registry.run(name: "shell", arguments: args)
    let out = try decodeShell(json)
    #expect(out.ok == true)
    #expect(out.exitCode == 7)
  }

  @Test func emptyCommandFails() async throws {
    let registry = ToolRegistry(tools: [ShellTool(), ReadFileTool(), WriteFileTool(), EditFileTool()])
    let args = try jsonArguments(["command": "   "])
    let json = await registry.run(name: "shell", arguments: args)
    let fail = try decodeFail(json)
    #expect(fail.ok == false)
    #expect(fail.error?.contains("command is empty") == true)
  }

  @Test func invalidWorkingDirectoryFails() async throws {
    let registry = ToolRegistry(tools: [ShellTool(), ReadFileTool(), WriteFileTool(), EditFileTool()])
    let bogusDir =
      FileManager.default.temporaryDirectory
      .appendingPathComponent("scribe-no-such-cwd-\(UUID().uuidString)", isDirectory: true)
    let args = try jsonArguments(["command": "/bin/true", "cwd": bogusDir.path])
    let json = await registry.run(name: "shell", arguments: args)
    let fail = try decodeFail(json)
    #expect(fail.ok == false)
    #expect(fail.error?.contains("path does not exist") == true)
  }

  /// Start a command that counts to a billion (should take many minutes),
  /// cancel the task, and confirm the process is killed in well under 15 seconds.
  @Test func interruptKillsLongRunningCommand() async throws {
    let registry = ToolRegistry(tools: [ShellTool()])
    // Pure shell loop — no external binaries, no output on stdout/stderr.
    let args = try jsonArguments([
      "command": "i=0; while [ $i -lt 1000000000 ]; do i=$((i+1)); done"
    ])

    let task = Task {
      await registry.run(name: "shell", arguments: args)
    }

    // Let the process start up.
    try await Task.sleep(for: .microseconds(400))

    // Simulate an interrupt by cancelling the task.
    task.cancel()

    let start = ContinuousClock.now
    let result: String = try await withThrowingTaskGroup(of: String.self) { group in
      group.addTask {
        await task.value
      }
      group.addTask {
        try await Task.sleep(for: .seconds(5))
        throw InterruptTimeoutError()
      }
      defer { group.cancelAll() }
      return try await group.next()!
    }
    let elapsed = start.duration(to: .now)

    #expect(elapsed < .seconds(5), "interrupt must kill the process within 15 seconds; took \(elapsed)")

    // When cancelled, the tool returns an error response (the CancellationError
    // propagates up through Subprocess → Shell.run → ToolRegistry.run).
    let fail = try decodeFail(result)
    #expect(fail.ok == false)
    // The error should indicate cancellation (not a different failure like "empty command").
    #expect(fail.error != nil)
    #expect(fail.error?.contains("empty") == false)
  }
}

private struct InterruptTimeoutError: Error, CustomStringConvertible {
  var description: String {
    "Interrupt test timed out after 15 seconds — the long-running process was not killed."
  }
}
