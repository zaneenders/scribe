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

  // MARK: - argumentSummary

  @Test func argumentSummaryShellWithCwdIncludesDirectory() {
    let summary = ToolInvocationFormatting.argumentSummary(
      name: "shell",
      argumentsJSON: "{\"command\": \"ls\", \"cwd\": \"/tmp\"}"
    )
    #expect(summary == "ls  (cwd: /tmp)")
  }

  @Test func argumentSummaryShellWithoutCwdShowsOnlyCommand() {
    let summary = ToolInvocationFormatting.argumentSummary(
      name: "shell",
      argumentsJSON: "{\"command\": \"pwd\"}"
    )
    #expect(summary == "pwd")
  }

  @Test func argumentSummaryShellWithEmptyCwdShowsOnlyCommand() {
    let summary = ToolInvocationFormatting.argumentSummary(
      name: "shell",
      argumentsJSON: "{\"command\": \"ls\", \"cwd\": \"   \"}"
    )
    #expect(summary == "ls")
  }

  @Test func argumentSummaryReadFileShowsPath() {
    let summary = ToolInvocationFormatting.argumentSummary(
      name: "read_file",
      argumentsJSON: "{\"path\": \"/tmp/foo.txt\", \"offset\": 10}"
    )
    #expect(summary == "/tmp/foo.txt")
  }

  @Test func argumentSummaryWriteFileShowsPath() {
    let summary = ToolInvocationFormatting.argumentSummary(
      name: "write_file",
      argumentsJSON: "{\"path\": \"out.txt\", \"content\": \"hi\"}"
    )
    #expect(summary == "out.txt")
  }

  @Test func argumentSummaryEditFileShowsPath() {
    let summary = ToolInvocationFormatting.argumentSummary(
      name: "edit_file",
      argumentsJSON: "{\"path\": \"src.swift\", \"old_string\": \"a\", \"new_string\": \"b\"}"
    )
    #expect(summary == "src.swift")
  }

  @Test func argumentSummaryUnknownToolReturnsNil() {
    let summary = ToolInvocationFormatting.argumentSummary(
      name: "unknown",
      argumentsJSON: "{}"
    )
    #expect(summary == nil)
  }

  @Test func argumentSummaryInvalidJSONReturnsNilForShell() {
    let summary = ToolInvocationFormatting.argumentSummary(
      name: "shell",
      argumentsJSON: "not json"
    )
    #expect(summary == nil)
  }

  // MARK: - outputLines for edit_file / write_file

  @Test func outputLinesEditFileReturnsReplaced() {
    let json = """
      {"ok":true,"replaced":true,"content":"new content"}
      """
    let lines = ToolInvocationFormatting.outputLines(name: "edit_file", jsonOutput: json)
    #expect(lines == ["replaced"])
  }

  @Test func outputLinesWriteFileReturnsWritten() {
    let json = """
      {"ok":true,"written":true}
      """
    let lines = ToolInvocationFormatting.outputLines(name: "write_file", jsonOutput: json)
    #expect(lines == ["written"])
  }

  // MARK: - outputLines for error cases

  @Test func outputLinesErrorShowsErrorMessage() {
    let json = """
      {"ok":false,"error":"path does not exist"}
      """
    let lines = ToolInvocationFormatting.outputLines(name: "shell", jsonOutput: json)
    #expect(lines == ["error: path does not exist"])
  }

  @Test func outputLinesErrorWithMissingErrorFieldShowsFallback() {
    let json = """
      {"ok":false}
      """
    let lines = ToolInvocationFormatting.outputLines(name: "shell", jsonOutput: json)
    #expect(lines == ["error: unknown error"])
  }

  // MARK: - outputLines for invalid JSON

  @Test func outputLinesInvalidJSONReturnsRawOutput() {
    let raw = "garbage"
    let lines = ToolInvocationFormatting.outputLines(name: "shell", jsonOutput: raw)
    #expect(lines == [raw])
  }

  // MARK: - readFileLogSummary

  @Test func readFileLogSummarySuccess() {
    let json = """
      {"ok":true,"path":"/tmp/f.txt","bytes":500,"total_lines":20,"start_line":1,"end_line":10,"truncated":true,"content":"abc"}
      """
    let summary = ToolInvocationFormatting.readFileLogSummary(jsonOutput: json)
    #expect(summary.contains("ok=true"))
    #expect(summary.contains("bytes=500"))
    #expect(summary.contains("truncated=true"))
    #expect(summary.contains("returned_lines=10"))
  }

  @Test func readFileLogSummaryError() {
    let json = """
      {"ok":false,"error":"path does not exist: /nope"}
      """
    let summary = ToolInvocationFormatting.readFileLogSummary(jsonOutput: json)
    #expect(summary.contains("ok=false"))
    #expect(summary.contains("path does not exist"))
  }

  @Test func readFileLogSummaryInvalidJSON() {
    let summary = ToolInvocationFormatting.readFileLogSummary(jsonOutput: "{{}")
    #expect(summary.contains("decode_failed=true"))
  }

  // MARK: - outputLines for shell edge cases

  @Test func shellEmptyStreamsWithExitCodeShowsExitOnly() {
    let json = """
      {"ok":true,"exit_code":0,"stdout":"","stderr":""}
      """
    let lines = ToolInvocationFormatting.outputLines(name: "shell", jsonOutput: json)
    #expect(lines == ["exit 0"])
  }

  @Test func shellEmptyStreamsWithoutExitCodeShowsPlaceholder() {
    let json = """
      {"ok":true,"stdout":"","stderr":""}
      """
    let lines = ToolInvocationFormatting.outputLines(name: "shell", jsonOutput: json)
    #expect(lines == ["(no output)"])
  }

  @Test func shellMissingExitCodeDoesNotShowExitLine() {
    let json = """
      {"ok":true,"stdout":"hi\\n","stderr":""}
      """
    let lines = ToolInvocationFormatting.outputLines(name: "shell", jsonOutput: json)
    #expect(!lines.contains { $0.starts(with: "exit ") })
    #expect(lines.contains("hi"))
  }

  // MARK: - readFileSummaryLine edge cases

  @Test func readFileSummaryOffsetPastEndShowsZeroLines() {
    let json = """
      {"ok":true,"path":"/tmp/f.txt","bytes":10,"total_lines":5,"start_line":6,"end_line":5,"truncated":false}
      """
    let lines = ToolInvocationFormatting.outputLines(name: "read_file", jsonOutput: json)
    #expect(lines.count == 1)
    #expect(lines[0].contains("offset past end"))
  }

  @Test func readFileSummaryNoStructuredFieldsFallsBackToChars() {
    let json = """
      {"ok":true,"content":"hello"}
      """
    let lines = ToolInvocationFormatting.outputLines(name: "read_file", jsonOutput: json)
    #expect(lines.count == 1)
    #expect(lines[0] == "5 chars")
  }

  @Test func readFileSummaryNoContentShowsPlaceholder() {
    let json = """
      {"ok":true}
      """
    let lines = ToolInvocationFormatting.outputLines(name: "read_file", jsonOutput: json)
    #expect(lines.count == 1)
    #expect(lines[0] == "(no content)")
  }

  // MARK: - outputLines for unknown tool with valid JSON

  @Test func outputLinesUnknownToolPrettyPrintsJSON() {
    let json = """
      {"ok":true,"extra":"value"}
      """
    let lines = ToolInvocationFormatting.outputLines(name: "unknown_tool", jsonOutput: json)
    // Should pretty-print if JSON is valid and small enough
    #expect(lines.count > 1)  // multi-line pretty-printed output
    #expect(lines.contains { $0.contains("\"extra\"") })
  }
}
