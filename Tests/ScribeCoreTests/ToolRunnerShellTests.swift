import SystemPackage
import Foundation
import Logging
import Subprocess
import Synchronization
import Testing

@testable import ScribeCore

@Suite
struct ToolRunnerShellTests {
  @Test func echoProducesStdout() async throws {
    let registry = ToolRegistry(tools: [ShellTool(), ReadFileTool(), WriteFileTool(), EditFileTool()])
    let args = try jsonArguments(["command": "/bin/echo scribetest"])
    let json = try! await registry.run(
      name: "shell", arguments: args, workingDirectory: FilePath("/tmp"), abortObserver: AbortNotifier()).text
    let out = try decodeShell(json)
    #expect(out.ok == true)
    #expect(out.exitCode == 0)
    #expect(out.pid != nil)
    #expect(out.pid! > 0)
    let stdout = try readFileIfExists(out.stdoutFile)
    #expect(stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "scribetest")
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
        name: "shell", arguments: args, workingDirectory: FilePath("/tmp"), abortObserver: AbortNotifier()).text
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
      name: "shell", arguments: args, workingDirectory: FilePath("/tmp"), abortObserver: AbortNotifier()).text
    let out = try decodeShell(json)
    #expect(out.ok == true)
    #expect(out.exitCode == 7)
  }

  @Test func emptyCommandFails() async throws {
    let registry = ToolRegistry(tools: [ShellTool(), ReadFileTool(), WriteFileTool(), EditFileTool()])
    let args = try jsonArguments(["command": "   "])
    let json = try! await registry.run(
      name: "shell", arguments: args, workingDirectory: FilePath("/tmp"), abortObserver: AbortNotifier()).text
    let fail = try decodeFail(json)
    #expect(fail.ok == false)
    #expect(fail.error?.contains("command is empty") == true)
  }

  @Test func emptyCwdIsTreatedAsNil() async throws {
    let registry = ToolRegistry(tools: [ShellTool(), ReadFileTool(), WriteFileTool(), EditFileTool()])
    let args = try jsonArguments(["command": "/bin/echo ok", "cwd": ""])
    let json = try! await registry.run(
      name: "shell", arguments: args, workingDirectory: FilePath("/tmp"), abortObserver: AbortNotifier()).text
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
      name: "shell", arguments: args, workingDirectory: FilePath("/tmp"), abortObserver: AbortNotifier()).text
    let fail = try decodeFail(json)
    #expect(fail.ok == false)
    #expect(fail.error?.contains("path does not exist") == true)
  }

  @Test func interruptKillsLongRunningCommand() async throws {
    let registry = ToolRegistry(tools: [ShellTool()])
    let args = try jsonArguments([
      "command": "i=0; while [ $i -lt 1000000000 ]; do i=$((i+1)); done"
    ])

    let notifier = AbortNotifier()
    let start = ContinuousClock.now

    do {
      _ = try await withThrowingTaskGroup(of: String.self) { group in
        group.addTask {
          try await registry.run(
            name: "shell",
            arguments: args,
            workingDirectory: FilePath("/tmp"),
            abortObserver: notifier
          ).text
        }
        group.addTask {
          try await Task.sleep(for: .milliseconds(200))
          notifier.request()
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
  @Test func interruptKillsProcessTreeWithSeparateGroups() async throws {
    let registry = ToolRegistry(tools: [ShellTool()])
    let args = try jsonArguments([
      "command": """
      setsid sh -c 'while true; do sleep 0.1; done' &
      CHILD=$!
      echo "CHILD=$CHILD"
      wait $CHILD
      """
    ])

    let notifier = AbortNotifier()
    let start = ContinuousClock.now

    do {
      _ = try await withThrowingTaskGroup(of: String.self) { group in
        group.addTask {
          try await registry.run(
            name: "shell",
            arguments: args,
            workingDirectory: FilePath("/tmp"),
            abortObserver: notifier
          ).text
        }
        group.addTask {
          try await Task.sleep(for: .milliseconds(500))
          notifier.request()
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

  @Test func cancellationInvokesKillerWithSubprocessPid() async throws {
    let spy = SpyProcessKiller()
    let command = "i=0; while [ $i -lt 1000000000 ]; do i=$((i+1)); done"

    let task = Task {
      try await Shell.run(
        command: command,
        cwd: nil,
        workingDirectory: FilePath("/tmp"),
        killer: spy)
    }
    try await Task.sleep(for: .milliseconds(200))
    task.cancel()

    _ = try? await task.value

    let invocations = spy.snapshot()
    #expect(invocations.count >= 1, "expected at least one killer invocation; got 0")
    if let first = invocations.first {
      #expect(first.rootPid > 0, "killer should have received a real subprocess pid; got \(first.rootPid)")
    }
  }

  @Test func killerNotInvokedOnNormalCompletion() async throws {
    let spy = SpyProcessKiller()
    let result = try await Shell.run(
      command: "/bin/echo hello",
      cwd: nil,
      workingDirectory: FilePath("/tmp"),
      killer: spy)
    #expect(result.exitCodeForJSON == 0)
    #expect(spy.snapshot().isEmpty, "killer should not be invoked when the task completes normally")
  }

  @Test func partialOutputPreservedOnInterrupt() async throws {
    let command =
      "i=0; while [ $i -lt 20000 ]; do echo \"line$i\"; i=$((i+1)); sleep 0.001; done"

    let task = Task {
      try await Shell.run(
        command: command, cwd: nil, workingDirectory: FilePath("/tmp"))
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

final class SpyProcessKiller: ProcessKiller, Sendable {
  struct Invocation: Sendable {
    let rootPid: pid_t
    let shellID: UUID
  }

  private struct State {
    var invocations: [Invocation] = []
  }
  private let state = Mutex(State())
  private let forward = DefaultProcessKiller()

  init() {}

  func killTree(
    rootPid: pid_t,
    execution: Subprocess.Execution,
    logger: Logger,
    shellID: UUID
  ) -> Int {
    state.withLock { $0.invocations.append(.init(rootPid: rootPid, shellID: shellID)) }
    return forward.killTree(
      rootPid: rootPid, execution: execution, logger: logger, shellID: shellID)
  }

  func snapshot() -> [Invocation] {
    state.withLock { $0.invocations }
  }
}

private func readFileIfExists(_ path: String?) throws -> String {
  guard let path else { return "" }
  return try String(contentsOfFile: path, encoding: .utf8)
}
