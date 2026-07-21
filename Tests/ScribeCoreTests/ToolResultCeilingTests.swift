import Foundation
import Logging
import SystemPackage
import Testing

@testable import ScribeCore

struct ToolResultCeilingTests {
  @Test func preservesResultsWithinGlobalCeiling() throws {
    let original = #"{"ok":true,"value":"small"}"#

    let result = ToolResult.text(original)

    #expect(result.text == original)
    #expect(result.textWasTruncated == false)
    #expect(result.warnings.isEmpty)
  }

  @Test func globallyTruncatesOversizedTextAsValidJSON() throws {
    let original = String(repeating: "x", count: ToolResult.maxTextCharacters + 20_000)

    let result = ToolResult.text(original)

    #expect(result.textWasTruncated == true)
    #expect(result.text.count <= ToolResult.maxTextCharacters)
    #expect(result.text.utf8.count <= ToolResult.maxTextBytes)
    #expect(result.warnings.count == 1)

    let data = try #require(result.text.data(using: .utf8))
    let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(object["tool_result_truncated"] as? Bool == true)
    #expect(object["truncation_reason"] as? String == "global_tool_result_limit")
    #expect(object["original_characters"] as? Int == original.count)
    #expect((object["content_preview"] as? String)?.isEmpty == false)
  }

  @Test func globalByteCeilingIsUnicodeSafe() throws {
    let original = String(repeating: "🙂", count: ToolResult.maxTextCharacters)

    let result = ToolResult.text(original)

    #expect(result.textWasTruncated == true)
    #expect(result.text.count <= ToolResult.maxTextCharacters)
    #expect(result.text.utf8.count <= ToolResult.maxTextBytes)
    #expect(result.text.data(using: .utf8) != nil)
  }

  @Test func ceilingDoesNotDiscardAttachmentsOrExistingWarnings() {
    let attachment = ToolAttachment(mimeType: "image/png", base64: "aGVsbG8=")
    let originalWarning = "existing warning"

    let result = ToolResult(
      text: String(repeating: "x", count: ToolResult.maxTextCharacters + 1),
      attachments: [attachment],
      warnings: [originalWarning])

    #expect(result.attachments.count == 1)
    #expect(result.attachments.first?.base64 == attachment.base64)
    #expect(result.warnings.first == originalWarning)
    #expect(result.warnings.count == 2)
  }

  @Test func registryAppliesCeilingToEveryEncodedToolResult() async throws {
    let registry = ToolRegistry(tools: [OversizedResultTool()], logger: toolRunnerTestLogger)

    let result = try await registry.run(
      name: OversizedResultTool.name,
      arguments: "{}",
      workingDirectory: FilePath("/tmp"),
      logger: toolRunnerTestLogger,
      abortObserver: AbortNotifier())

    #expect(result.textWasTruncated == true)
    #expect(result.text.count <= ToolResult.maxTextCharacters)
    #expect(result.text.utf8.count <= ToolResult.maxTextBytes)
  }
}

private struct OversizedResultTool: ScribeTool {
  static let name = "oversized_result"
  static let description = "Returns an oversized result"
  static let parameters: [ScribeToolParameter] = []
  static let promptHint: String? = nil

  func run(arguments: String, workingDirectory: FilePath, logger: Logging.Logger) async throws -> Encodable {
    OversizedPayload(content: String(repeating: "x", count: ToolResult.maxTextCharacters + 20_000))
  }
}

private struct OversizedPayload: Encodable {
  let content: String
}
