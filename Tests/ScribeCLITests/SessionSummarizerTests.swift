import Foundation
import ScribeCore
import Testing

@testable import ScribeCLI
@testable import ScribeKit

@Suite
struct SessionSummarizerTests {

  @Test func renderSliceFormatsAssistantToolAndResults() {
    let slice: [ScribeMessage] = [
      ScribeMessage(
        role: .assistant, content: "Let me check the file.",
        toolCalls: [ScribeToolCall(id: "c1", name: "read_file", arguments: "{\"path\":\"a.txt\"}")]
      ),
      ScribeMessage(role: .tool, content: "file contents here", name: "read_file", toolCallId: "c1"),
      ScribeMessage(role: .assistant, content: "Done."),
    ]
    let rendered = SessionSummarizer.renderSlice(slice)
    #expect(rendered.contains("Assistant: Let me check the file."))
    #expect(rendered.contains("[tool call: read_file {\"path\":\"a.txt\"}]"))
    #expect(rendered.contains("Tool result (read_file): file contents here"))
    #expect(rendered.contains("Assistant: Done."))
  }

  @Test func renderSliceSkipsEmptyAssistantText() {

    let slice: [ScribeMessage] = [
      ScribeMessage(
        role: .assistant, content: "",
        toolCalls: [ScribeToolCall(id: "c1", name: "shell", arguments: "{}")]
      )
    ]
    let rendered = SessionSummarizer.renderSlice(slice)
    #expect(!rendered.contains("Assistant: "))
    #expect(rendered.contains("[tool call: shell"))
  }

  @Test func renderSliceHandlesEmptySlice() {
    #expect(SessionSummarizer.renderSlice([]) == "")
  }
}
