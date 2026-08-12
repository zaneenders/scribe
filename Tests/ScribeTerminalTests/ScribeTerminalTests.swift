import Foundation
import ScribeTerminal
import Testing

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
    session.write("echo scribe-pty-$((40+2))\n")

    let deadline = ContinuousClock.now + .seconds(15)
    while ContinuousClock.now < deadline {
      if buffer.text.contains("scribe-pty-42") { return }
      try await Task.sleep(for: .milliseconds(100))
    }
    Issue.record("Never saw shell output; received: \(buffer.text.suffix(500))")
  }
}
#endif
