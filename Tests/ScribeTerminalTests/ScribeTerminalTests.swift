import Foundation
import ScribeTerminal
import Synchronization
import Testing

#if canImport(AppKit)
import AppKit
#endif

@Suite("GhosttyTerminal")
struct GhosttyTerminalTests {
  @Test func parsesVTAndFormatsActiveScreen() throws {
    let terminal = try GhosttyTerminal(columns: 20, rows: 3)
    terminal.write("Hello, \u{1B}[1;32mGhostty\u{1B}[0m!\r\nsecond line")

    #expect(terminal.plainText.contains("Hello, Ghostty!"))
    #expect(terminal.plainText.contains("second line"))
  }

  @Test func retainsAndScrollsThroughHistory() throws {
    let terminal = try GhosttyTerminal(columns: 20, rows: 3)
    for index in 1...20 { terminal.write("line \(index)\r\n") }

    #expect(terminal.plainText.contains("line 20"))
    terminal.scroll(lines: -10)
    #expect(terminal.plainText.contains("line 10"))
  }

  @Test func resetClearsTheScreen() throws {
    let terminal = try GhosttyTerminal(columns: 20, rows: 3)
    terminal.write("before reset")
    terminal.reset()

    #expect(!terminal.plainText.contains("before reset"))
  }

  @Test func tabEncodesForShellCompletion() throws {
    let terminal = try GhosttyTerminal(columns: 20, rows: 3)

    #expect(terminal.encodeKey(.tab) == Data([0x09]))
  }

  @Test func arrowKeysFollowTerminalCursorMode() throws {
    let terminal = try GhosttyTerminal(columns: 20, rows: 3)

    #expect(terminal.encodeKey(.arrowUp) == Data("\u{1B}[A".utf8))
    #expect(terminal.encodeKey(.arrowDown) == Data("\u{1B}[B".utf8))

    terminal.write("\u{1B}[?1h")
    #expect(terminal.encodeKey(.arrowUp) == Data("\u{1B}OA".utf8))
    #expect(terminal.encodeKey(.arrowDown) == Data("\u{1B}OB".utf8))
  }

  #if os(macOS)
  @MainActor
  @Test func osc52WritesTheSystemClipboard() throws {
    let terminal = try GhosttyTerminal(columns: 20, rows: 3)
    NSPasteboard.general.clearContents()

    terminal.write("\u{1B}]52;c;c2NyaWJlLW9zYzUy\u{7}")

    #expect(NSPasteboard.general.string(forType: .string) == "scribe-osc52")
  }
  #endif
}

#if os(macOS)
@Suite("PTYSession")
struct PTYSessionTests {
  /// Accumulates PTY output from the read thread.
  private final class OutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
      lock.withLock { data.append(chunk) }
    }

    var text: String {
      lock.withLock { String(decoding: data, as: UTF8.self) }
    }
  }

  @Test func shellEchoesWrittenMarker() async throws {
    let session = try PTYSession()
    defer { session.close() }

    let buffer = OutputBuffer()
    session.onOutput = { data in buffer.append(data) }

    // Arithmetic expansion keeps the TTY's own echo of the typed command from
    // satisfying the check; only the shell's output contains the marker.
    try session.write("echo scribe-pty-$((40+2))\n")

    let deadline = ContinuousClock.now + .seconds(15)
    while ContinuousClock.now < deadline {
      if buffer.text.contains("scribe-pty-42") { return }
      try await Task.sleep(for: .milliseconds(100))
    }
    Issue.record("Never saw shell output; received: \(buffer.text.suffix(500))")
  }
}

@Suite("TerminalRuntime")
struct TerminalRuntimeTests {
  private func makeClient(
    replayBytes: Int = 1024 * 1024,
    attachmentEvents: Int = 64
  ) -> InProcessTerminalClient {
    InProcessTerminalClient(
      runtime: TerminalRuntime(
        limits: .init(replayBytes: replayBytes, attachmentEvents: attachmentEvents)))
  }

  private func output(
    from attachment: TerminalAttachment,
    until marker: String
  ) async throws -> (String, UInt64) {
    var text = ""
    var cursor: UInt64 = 0
    for try await event in attachment.events {
      switch event {
      case .output(let output):
        text += String(decoding: output.data, as: UTF8.self)
        cursor = output.endCursor
        if text.contains(marker) { return (text, cursor) }
      case .exit(let status):
        throw RuntimeTestError.exitedBeforeMarker(status)
      }
    }
    throw RuntimeTestError.streamEndedBeforeMarker
  }

  @Test func localCallbackCanReenterRuntimeWithoutDeadlocking() throws {
    let client = makeClient()
    let id = try client.createSynchronously(
      configuration: TerminalConfiguration(shell: "/bin/sh"))
    defer { client.closeSynchronously(id) }
    let reentryState = Atomic<UInt8>(0)
    let attachment = try client.attachSynchronously(to: id) { event in
      guard case .output = event else { return }
      if reentryState.compareExchange(expected: 0, desired: 1, ordering: .relaxed).exchanged {
        try? client.writeSynchronously("echo reentered\n", to: id)
        reentryState.store(2, ordering: .relaxed)
      }
    }
    defer { client.runtime.detachLocal(attachment.id, from: attachment.terminalID) }

    try client.writeSynchronously("echo initial\n", to: id)
    let deadline = ContinuousClock.now + .seconds(1)
    while reentryState.load(ordering: .relaxed) != 2, ContinuousClock.now < deadline {
      Thread.sleep(forTimeInterval: 0.001)
    }
    #expect(reentryState.load(ordering: .relaxed) == 2)
  }

  @Test func outputAndInputFlowThroughInProcessClient() async throws {
    let client = makeClient()
    let id = try await client.createTerminal(
      configuration: TerminalConfiguration(shell: "/bin/sh"))
    defer { Task { await client.close(id) } }
    let attachment = try await client.attach(to: id, after: nil)

    try await client.write("echo runtime-$((6*7))\n", to: id)
    let (text, _) = try await output(from: attachment, until: "runtime-42")

    #expect(text.contains("runtime-42"))
  }

  @Test func resizeChangesPTYWindowSize() async throws {
    let client = makeClient()
    let id = try await client.createTerminal(
      configuration: TerminalConfiguration(shell: "/bin/sh"))
    defer { Task { await client.close(id) } }
    let attachment = try await client.attach(to: id, after: nil)

    try await client.resize(id, to: TerminalSize(columns: 101, rows: 37))
    try await client.write("stty size; echo resize-$((6*7))\n", to: id)
    let (text, _) = try await output(from: attachment, until: "resize-42")

    #expect(text.contains("37 101"))
  }

  @Test func exitIsDeliveredAfterFinalOutputAndFinishesAttachment() async throws {
    let client = makeClient(attachmentEvents: 4_096)
    let id = try await client.createTerminal(
      configuration: TerminalConfiguration(shell: "/bin/sh"))
    let attachment = try await client.attach(to: id, after: nil)

    let payload = String(repeating: "terminal-final-output-", count: 2_000)
    try await client.write(
      "i=0; while [ $i -lt 2000 ]; do printf terminal-final-output-; i=$((i+1)); done; exit 7\n",
      to: id)
    var received = Data()
    var exitStatus: Int32?
    var receivedOutputAfterExit = false
    for try await event in attachment.events {
      switch event {
      case .output(let output):
        if exitStatus != nil { receivedOutputAfterExit = true }
        received.append(output.data)
      case .exit(let status):
        exitStatus = status
      }
    }

    #expect(String(decoding: received, as: UTF8.self).contains(payload))
    #expect(!receivedOutputAfterExit)
    #expect(exitStatus.map { ($0 >> 8) & 0xff } == 7)

    let status = try #require(exitStatus)
    let expectedError = TerminalRuntimeError.terminalExited(id, status: status)
    await #expect(throws: expectedError) {
      try await client.write("ignored", to: id)
    }
    await #expect(throws: expectedError) {
      try await client.resize(id, to: TerminalSize(columns: 90, rows: 30))
    }
  }

  @Test func attachReplaysFromByteCursor() async throws {
    let client = makeClient()
    let id = try await client.createTerminal(
      configuration: TerminalConfiguration(shell: "/bin/sh"))
    defer { Task { await client.close(id) } }
    let first = try await client.attach(to: id, after: nil)

    try await client.write("printf 'alpha-beta-replay\\n'\n", to: id)
    let (_, endCursor) = try await output(from: first, until: "alpha-beta-replay")
    await first.detach()

    let replay = try await client.attach(to: id, after: endCursor - 6)
    var iterator = replay.events.makeAsyncIterator()
    let event = try await iterator.next()
    guard case .output(let output)? = event else {
      Issue.record("Expected replay output")
      return
    }
    #expect(output.cursor == endCursor - 6)
    #expect(output.endCursor >= endCursor)
  }

  @Test func replayIsBoundedAndRejectsExpiredCursor() async throws {
    let client = makeClient(replayBytes: 32)
    let id = try await client.createTerminal(
      configuration: TerminalConfiguration(shell: "/bin/sh"))
    defer { Task { await client.close(id) } }
    let first = try await client.attach(to: id, after: nil)

    try await client.write("printf 'abcdefghijklmnopqrstuvwxyz-BOUNDARY\\n'\n", to: id)
    _ = try await output(from: first, until: "BOUNDARY")
    await first.detach()

    await #expect(throws: TerminalRuntimeError.self) {
      _ = try await client.attach(to: id, after: 0)
    }
  }

  @Test func slowConsumerIsDisconnectedWithoutBlockingOthers() async throws {
    let client = makeClient(attachmentEvents: 64)
    let id = try await client.createTerminal(
      configuration: TerminalConfiguration(shell: "/bin/sh"))
    defer { Task { await client.close(id) } }
    let slow = try await client.attach(to: id, after: nil)
    let fast = try await client.attach(to: id, after: nil)

    let fastTask = Task { try await output(from: fast, until: "slow-consumer-finished") }
    for index in 0..<500 {
      try await client.write("echo chunk-\(index)\n", to: id)
      try await Task.sleep(for: .milliseconds(5))
    }
    try await client.write("echo slow-consumer-finished\n", to: id)
    let (fastText, _) = try await fastTask.value
    #expect(fastText.contains("slow-consumer-finished"))

    var sawSlowConsumer = false
    do {
      for try await _ in slow.events {}
    } catch TerminalRuntimeError.slowConsumer {
      sawSlowConsumer = true
    }
    #expect(sawSlowConsumer)
  }

  private enum RuntimeTestError: Error {
    case exitedBeforeMarker(Int32)
    case streamEndedBeforeMarker
  }
}
#endif
