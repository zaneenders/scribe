#!/usr/bin/env swift
#if os(macOS)
import Darwin
import Foundation

struct SmokeFailure: Error, CustomStringConvertible {
  let description: String
}

func require(_ condition: Bool, _ message: String) throws {
  if !condition { throw SmokeFailure(description: message) }
}

func line(from handle: FileHandle, timeout: TimeInterval = 30) throws -> String {
  let deadline = ProcessInfo.processInfo.systemUptime + timeout
  var data = Data()
  while ProcessInfo.processInfo.systemUptime < deadline {
    var descriptor = pollfd(fd: handle.fileDescriptor, events: Int16(POLLIN), revents: 0)
    let result = poll(&descriptor, 1, 100)
    if result < 0 && errno == EINTR { continue }
    try require(result >= 0, "Readiness poll failed")
    if result == 0 { continue }
    guard let byte = try handle.read(upToCount: 1), !byte.isEmpty else {
      throw SmokeFailure(description: "Process exited before readiness")
    }
    if byte == Data([10]) { return String(decoding: data, as: UTF8.self) }
    data.append(byte)
    try require(data.count <= 32, "Invalid readiness response")
  }
  throw SmokeFailure(description: "Readiness timed out")
}

func ready(_ output: FileHandle) throws -> String {
  let response = try line(from: output)
  try require(Int(response).map { (1...65535).contains($0) } == true, "Invalid port: \(response)")
  return response
}

func launch(_ executable: URL, arguments: [String]) throws -> (Process, Pipe, Pipe) {
  let process = Process()
  let input = Pipe()
  let output = Pipe()
  process.executableURL = executable
  process.arguments = arguments
  process.standardInput = input
  process.standardOutput = output
  process.standardError = FileHandle.standardError
  try process.run()
  try input.fileHandleForReading.close()
  try output.fileHandleForWriting.close()
  return (process, input, output)
}

func cleanup(_ process: Process) {
  if process.isRunning { kill(process.processIdentifier, SIGKILL) }
  process.waitUntilExit()
}

func waitForExit(_ process: Process) throws {
  let deadline = ProcessInfo.processInfo.systemUptime + 5
  while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline {
    Thread.sleep(forTimeInterval: 0.05)
  }
  try require(!process.isRunning, "Process did not exit")
  process.waitUntilExit()
}

func run() throws {
  let arguments = Array(CommandLine.arguments.dropFirst())
  let ownerMode = arguments.first == "--owner"
  try require(
    arguments.count == (ownerMode ? 2 : 1),
    "usage: swift Scripts/test-backend-lifecycle.swift .build/debug/scribe-mac")
  let executable = URL(fileURLWithPath: arguments.last!)
  if ownerMode {
    let (child, input, output) = try launch(executable, arguments: ["--backend"])
    defer { cleanup(child) }
    print(child.processIdentifier)
    fflush(stdout)
    print(try ready(output.fileHandleForReading))
    fflush(stdout)
    withExtendedLifetime(input) { Thread.sleep(forTimeInterval: 60) }
    return
  }

  // Closing the owning pipe must shut down the actual headless backend.
  do {
    let (child, input, output) = try launch(executable, arguments: ["--backend"])
    defer { cleanup(child) }
    _ = try ready(output.fileHandleForReading)
    try input.fileHandleForWriting.close()
    try waitForExit(child)
    try require(child.terminationStatus == 0, "Backend failed during EOF shutdown")
  }

  // A separate Swift owner holds stdin open. SIGKILL must still produce EOF.
  let script = URL(fileURLWithPath: CommandLine.arguments[0]).path
  let (owner, input, output) = try launch(
    URL(fileURLWithPath: "/usr/bin/swift"),
    arguments: [script, "--owner", executable.path])
  defer {
    cleanup(owner)
    try? input.fileHandleForWriting.close()
  }
  guard let pid = Int32(try line(from: output.fileHandleForReading)) else {
    throw SmokeFailure(description: "Invalid backend PID")
  }
  var backendExited = false
  defer { if !backendExited { kill(pid, SIGKILL) } }
  _ = try ready(output.fileHandleForReading)
  kill(owner.processIdentifier, SIGKILL)
  try waitForExit(owner)
  let deadline = ProcessInfo.processInfo.systemUptime + 5
  while ProcessInfo.processInfo.systemUptime < deadline {
    if kill(pid, 0) == -1 && errno == ESRCH {
      backendExited = true
      break
    }
    Thread.sleep(forTimeInterval: 0.05)
  }
  try require(backendExited, "Backend survived abrupt parent death")
  print("PASS: actual backend exits on normal EOF and abrupt parent death")
}

try run()
#else
#error("The scribe-mac backend lifecycle smoke test requires macOS")
#endif
