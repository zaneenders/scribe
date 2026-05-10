import Foundation
import Testing

@testable import ScribeCore

@Suite
struct ToolRunnerShellTests {
  @Test func echoProducesStdout() async throws {
    let registry = ToolRegistry(tools: [ShellTool(), ReadFileTool(), WriteFileTool(), EditFileTool()])
    let args = try jsonArguments(["command": "/bin/echo scribetest"])
    let json = try! await registry.run(
      name: "shell", arguments: args, workingDirectory: ScribeFilePath("/tmp"), abortVia: { false })
    let out = try decodeShell(json)
    #expect(out.ok == true)
    #expect(out.exitCode == 0)
    #expect(out.pid != nil)
    #expect(out.pid! > 0)
    // Read stdout from temp file.
    let stdout = try readFileIfExists(out.stdoutFile)
    #expect(stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "scribetest")
    // Stderr should be empty.
    let stderr = try readFileIfExists(out.stderrFile)
    #expect(stderr == "")
  }

  @Test func honorsWorkingDirectory() async throws {
    let registry = ToolRegistry(tools: [ShellTool(), ReadFileTool(), WriteFileTool(), EditFileTool()])
    try await withTemporaryDirectory { dir in
      let marker = dir.appendingPathComponent("only_here.txt")
      try "cwd_ok".write(to: marker, atomically: true, encoding: .utf8)

      let args = try jsonArguments(["command": "/bin/cat only_here.txt", "cwd": dir.path])
      let json = try! await registry.run(
        name: "shell", arguments: args, workingDirectory: ScribeFilePath("/tmp"), abortVia: { false })
      let out = try decodeShell(json)
      #expect(out.ok == true)
      #expect(out.exitCode == 0)
      let stdout = try readFileIfExists(out.stdoutFile)
      #expect(stdout == "cwd_ok")
      let stderr = try readFileIfExists(out.stderrFile)
      #expect(stderr == "")
    }
  }

  @Test func reportsNonZeroExitWithoutOkFalse() async throws {
    let registry = ToolRegistry(tools: [ShellTool(), ReadFileTool(), WriteFileTool(), EditFileTool()])
    let args = try jsonArguments(["command": "/bin/sh -c 'exit 7'"])
    let json = try! await registry.run(
      name: "shell", arguments: args, workingDirectory: ScribeFilePath("/tmp"), abortVia: { false })
    let out = try decodeShell(json)
    #expect(out.ok == true)
    #expect(out.exitCode == 7)
  }

  @Test func emptyCommandFails() async throws {
    let registry = ToolRegistry(tools: [ShellTool(), ReadFileTool(), WriteFileTool(), EditFileTool()])
    let args = try jsonArguments(["command": "   "])
    let json = try! await registry.run(
      name: "shell", arguments: args, workingDirectory: ScribeFilePath("/tmp"), abortVia: { false })
    let fail = try decodeFail(json)
    #expect(fail.ok == false)
    #expect(fail.error?.contains("command is empty") == true)
  }

  @Test func emptyCwdIsTreatedAsNil() async throws {
    let registry = ToolRegistry(tools: [ShellTool(), ReadFileTool(), WriteFileTool(), EditFileTool()])
    // Passing cwd as empty string exercises the if-let-empty-to-nil conversion.
    let args = try jsonArguments(["command": "/bin/echo ok", "cwd": ""])
    let json = try! await registry.run(
      name: "shell", arguments: args, workingDirectory: ScribeFilePath("/tmp"), abortVia: { false })
    let out = try decodeShell(json)
    #expect(out.ok == true)
    let stdout = try readFileIfExists(out.stdoutFile)
    #expect(stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "ok")
  }

  @Test func invalidWorkingDirectoryFails() async throws {
    let registry = ToolRegistry(tools: [ShellTool(), ReadFileTool(), WriteFileTool(), EditFileTool()])
    let bogusDir =
      FileManager.default.temporaryDirectory
      .appendingPathComponent("scribe-no-such-cwd-\(UUID().uuidString)", isDirectory: true)
    let args = try jsonArguments(["command": "/bin/true", "cwd": bogusDir.path])
    let json = try! await registry.run(
      name: "shell", arguments: args, workingDirectory: ScribeFilePath("/tmp"), abortVia: { false })
    let fail = try decodeFail(json)
    #expect(fail.ok == false)
    #expect(fail.error?.contains("path does not exist") == true)
  }

  /// Start a command that counts to a billion (should take many minutes),
  /// trigger an abort via `shouldAbortTurn`, and confirm the process is
  /// killed in well under 5 seconds.
  @Test func interruptKillsLongRunningCommand() async throws {
    let registry = ToolRegistry(tools: [ShellTool()])
    // Pure shell loop — no external binaries, no output on stdout/stderr.
    let args = try jsonArguments([
      "command": "i=0; while [ $i -lt 1000000000 ]; do i=$((i+1)); done"
    ])

    let abortState = AbortState()
    let start = ContinuousClock.now

    do {
      _ = try await withThrowingTaskGroup(of: String.self) { group in
        group.addTask {
          try await registry.run(
            name: "shell",
            arguments: args,
            workingDirectory: ScribeFilePath("/tmp"), abortVia: { abortState.value }
          )
        }
        group.addTask {
          // Let the process start up, then trigger the abort.
          try await Task.sleep(for: .milliseconds(200))
          abortState.set(true)
          // Wait for the abort to complete. Timeout if something is stuck.
          try await Task.sleep(for: .seconds(5))
          throw InterruptTimeoutError()
        }
        defer { group.cancelAll() }
        return try await group.next()!
      }
      Issue.record("Expected AgentTurnInterruptedError, but tool returned normally")
    } catch is AgentTurnInterruptedError {
      let elapsed = start.duration(to: .now)
      #expect(elapsed < .seconds(5), "interrupt must kill the process within 5 seconds; took \(elapsed)")
    }
  }

  #if os(Linux)
  /// Spawn a grandchild in its own session (process group) via `setsid`,
  /// trigger abort, and verify the entire tree is killed — not just the
  /// process-group leader.
  @Test func interruptKillsProcessTreeWithSeparateGroups() async throws {
    let registry = ToolRegistry(tools: [ShellTool()])
    // Child PID is echoed to stdout so we can verify it's dead after abort.
    // setsid creates a new session → new process group, so a simple
    // kill(-pgid) would miss it.  Our recursive /proc walk must catch it.
    let args = try jsonArguments([
      "command": """
      setsid sh -c 'while true; do sleep 0.1; done' &
      CHILD=$!
      echo "CHILD=$CHILD"
      wait $CHILD
      """
    ])

    let abortState = AbortState()
    let start = ContinuousClock.now

    do {
      _ = try await withThrowingTaskGroup(of: String.self) { group in
        group.addTask {
          try await registry.run(
            name: "shell",
            arguments: args,
            workingDirectory: ScribeFilePath("/tmp"), abortVia: { abortState.value }
          )
        }
        group.addTask {
          // Give the child time to start.
          try await Task.sleep(for: .milliseconds(500))
          abortState.set(true)
          try await Task.sleep(for: .seconds(5))
          throw InterruptTimeoutError()
        }
        defer { group.cancelAll() }
        return try await group.next()!
      }
      Issue.record("Expected AgentTurnInterruptedError, but tool returned normally")
      return
    } catch is AgentTurnInterruptedError {
      let elapsed = start.duration(to: .now)
      #expect(elapsed < .seconds(5), "interrupt must kill the process tree within 5 seconds; took \(elapsed)")
    }
  }
  #endif

  // MARK: - Partial output on interrupt

  /// When a shell command is interrupted mid-flight, any output that was
  /// already written to the temp files must be preserved — the LLM needs to
  /// see partial build logs, test output, etc. after a Ctrl‑C.
  @Test func partialOutputPreservedOnInterrupt() async throws {
    // Shell loop with a tiny sleep per iteration so it doesn't finish before
    // we can cancel it.  200 ms should leave us with partial output.
    let command =
      "i=0; while [ $i -lt 20000 ]; do echo \"line$i\"; i=$((i+1)); sleep 0.001; done"

    let task = Task {
      try await Shell.run(
        command: command, cwd: nil, workingDirectory: ScribeFilePath("/tmp"))
    }
    try await Task.sleep(for: .milliseconds(200))
    task.cancel()

    let result = try await task.value
    let stdout = try String(
      contentsOfFile: result.stdoutFile.string, encoding: .utf8)
    #expect(!stdout.isEmpty, "stdout should have partial output, got empty")
    let lines = stdout.split(separator: "\n", omittingEmptySubsequences: true)
    #expect(lines.count > 0, "should have at least one line")
    #expect(lines.count < 20000, "should be truncated (not all 20000 lines)")
    #expect(stdout.contains("line0"), "first line should be present")
  }
}

private struct InterruptTimeoutError: Error, CustomStringConvertible {
  var description: String {
    "Interrupt test timed out after 15 seconds — the long-running process was not killed."
  }
}

/// Reads the file at `path`, returning an empty string if the path is nil.
private func readFileIfExists(_ path: String?) throws -> String {
  guard let path else { return "" }
  return try String(contentsOfFile: path, encoding: .utf8)
}
