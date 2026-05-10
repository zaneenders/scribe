import Foundation
import ScribeCLI
import Testing

/// Behaviour tests for the *transcript-display* formatting layer. The agent's conversation
/// history with the model still receives raw JSON tool output verbatim — these tests cover
/// only what the human-facing UI sees.
@Suite
struct ToolInvocationFormattingTests {
  // MARK: - shell

  @Test func shellShowsExitCodeAndFilePaths() {
    let json = """
      {"ok":true,"exit_code":0,"stdout_file":"/tmp/scribe-shell-uuid-stdout.txt","stderr_file":"/tmp/scribe-shell-uuid-stderr.txt"}
      """
    let lines = ToolInvocationFormatting.outputLines(name: "shell", jsonOutput: json)
    #expect(lines.contains("exit 0"))
    #expect(lines.contains { $0.hasPrefix("stdout → /tmp/scribe-shell-uuid-stdout.txt") })
    #expect(lines.contains { $0.hasPrefix("stderr → /tmp/scribe-shell-uuid-stderr.txt") })
  }

  @Test func shellFilePathsReplaceInlineContent() {
    // Even with stdout_file present, no inline content is shown — just the path.
    let json = """
      {"ok":true,"exit_code":1,"stdout_file":"/tmp/scribe-shell-out.txt","stderr_file":"/tmp/scribe-shell-err.txt"}
      """
    let lines = ToolInvocationFormatting.outputLines(name: "shell", jsonOutput: json)
    #expect(lines.contains("exit 1"))
    #expect(lines.contains { $0.hasPrefix("stdout → ") })
    #expect(lines.contains { $0.hasPrefix("stderr → ") })
    // No raw content lines leaking through.
    #expect(lines.allSatisfy { !$0.hasPrefix("hello") && !$0.hasPrefix("world") })
  }

  @Test func shellWithoutStderrFileOmitsStderrLine() {
    let json = """
      {"ok":true,"exit_code":0,"stdout_file":"/tmp/f.txt"}
      """
    let lines = ToolInvocationFormatting.outputLines(name: "shell", jsonOutput: json)
    #expect(lines.contains("exit 0"))
    #expect(lines.contains { $0.hasPrefix("stdout → ") })
    #expect(lines.allSatisfy { !$0.hasPrefix("stderr → ") })
  }

  @Test func shellWithoutStdoutFileOmitsStdoutLine() {
    let json = """
      {"ok":true,"exit_code":0,"stderr_file":"/tmp/e.txt"}
      """
    let lines = ToolInvocationFormatting.outputLines(name: "shell", jsonOutput: json)
    #expect(lines.contains("exit 0"))
    #expect(lines.contains { $0.hasPrefix("stderr → ") })
    #expect(lines.allSatisfy { !$0.hasPrefix("stdout → ") })
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

  // MARK: - outputLines for shell edge cases

  @Test func shellEmptyStreamsWithExitCodeShowsExitOnly() {
    // When both file paths are present but files are empty, we still show them.
    let json = """
      {"ok":true,"exit_code":0,"stdout_file":"/tmp/out.txt","stderr_file":"/tmp/err.txt"}
      """
    let lines = ToolInvocationFormatting.outputLines(name: "shell", jsonOutput: json)
    #expect(lines.contains("exit 0"))
    #expect(lines.contains { $0.hasPrefix("stdout → ") })
    #expect(lines.contains { $0.hasPrefix("stderr → ") })
  }

  @Test func shellEmptyStreamsWithoutExitCodeShowsPlaceholder() {
    // No exit_code and no file paths → nothing to show.
    let json = """
      {"ok":true}
      """
    let lines = ToolInvocationFormatting.outputLines(name: "shell", jsonOutput: json)
    #expect(lines == ["(no output)"])
  }

  @Test func shellMissingExitCodeDoesNotShowExitLine() {
    let json = """
      {"ok":true,"stdout_file":"/tmp/f.txt"}
      """
    let lines = ToolInvocationFormatting.outputLines(name: "shell", jsonOutput: json)
    #expect(!lines.contains { $0.starts(with: "exit ") })
    #expect(lines.contains { $0.hasPrefix("stdout → /tmp/f.txt") })
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
