import Foundation
import ScribeCore
import Testing

/// Behaviour tests for the *transcript-display* formatting layer. The agent's conversation
/// history with the model still receives raw JSON tool output verbatim — these tests cover
/// only what the human-facing UI sees.
@Suite
struct ToolInvocationFormattingTests {
  // MARK: - shell

  @Test func shellShortStdoutIsRenderedVerbatim() {
    let json = """
      {"ok":true,"exit_code":0,"stdout":"hello\\nworld\\n","stderr":""}
      """
    let lines = ToolInvocationFormatting.outputLines(name: "shell", jsonOutput: json)
    #expect(lines.contains("exit 0"))
    #expect(lines.contains("hello"))
    #expect(lines.contains("world"))
    #expect(lines.allSatisfy { !$0.contains("hidden") })
  }

  @Test func shellStdoutOver200LinesIsTruncatedHeadAndTail() {
    let body = (1...500).map { "line\($0)" }.joined(separator: "\n")
    let json = """
      {"ok":true,"exit_code":0,"stdout":\(stringJSON(body)),"stderr":""}
      """
    let lines = ToolInvocationFormatting.outputLines(name: "shell", jsonOutput: json)
    // Cap is 200 (120 head + 60 tail + 1 marker = 181 stream lines), plus "exit 0" + "stdout:".
    #expect(lines.count < 500)
    #expect(lines.contains("line1"))
    #expect(lines.contains("line500"))
    #expect(lines.contains { $0.contains("hidden") })
    // Specifically, the gap between head and tail must remove the middle range.
    #expect(!lines.contains("line250"))
  }

  @Test func shellStderrIsTruncatedIndependentlyOfStdout() {
    let stdoutBody = "ok\n"
    let stderrBody = (1...400).map { "err\($0)" }.joined(separator: "\n")
    let json = """
      {"ok":true,"exit_code":1,"stdout":\(stringJSON(stdoutBody)),"stderr":\(stringJSON(stderrBody))}
      """
    let lines = ToolInvocationFormatting.outputLines(name: "shell", jsonOutput: json)
    #expect(lines.contains("ok"))
    #expect(lines.contains("err1"))
    #expect(lines.contains("err400"))
    #expect(lines.contains { $0.contains("hidden") })
  }

  // MARK: - read_file (sanity check that the existing summary line keeps working)

  @Test func readFileReturnsSingleSummaryLine() {
    let json = """
      {"ok":true,"path":"/tmp/foo.txt","content":"abc","bytes":3,"total_lines":1,"start_line":1,"end_line":1,"truncated":false}
      """
    let lines = ToolInvocationFormatting.outputLines(name: "read_file", jsonOutput: json)
    #expect(lines.count == 1)
    #expect(lines[0].contains("3 bytes"))
    #expect(lines[0].contains("returned 1–1"))
  }

  /// Hand-rolled JSON string escape so the test does not pull in `JSONEncoder` plumbing
  /// just to embed a multi-line literal. Only the cases we use here (`\` and `"` and `\n`)
  /// are handled.
  private func stringJSON(_ s: String) -> String {
    var escaped = ""
    escaped.reserveCapacity(s.count + 2)
    escaped.append("\"")
    for ch in s {
      switch ch {
      case "\\": escaped.append("\\\\")
      case "\"": escaped.append("\\\"")
      case "\n": escaped.append("\\n")
      case "\r": escaped.append("\\r")
      case "\t": escaped.append("\\t")
      default: escaped.append(ch)
      }
    }
    escaped.append("\"")
    return escaped
  }
}
