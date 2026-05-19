import Foundation
import Testing

@testable import ScribeCore

@Suite
struct ToolRunnerReadImageTests {

  @Test func readFileReturnsBase64ForImage() async throws {
    let registry = ToolRegistry(tools: [ReadFileTool()])
    try await withTemporaryDirectory { dir in
      let imageURL = dir.appendingPathComponent("test.png")
      let data = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
      try data.write(to: imageURL)

      let args = try jsonArguments(["path": imageURL.path])
      let json = try! await registry.run(
        name: "read_file",
        arguments: args,
        workingDirectory: ScribeFilePath("/tmp"),
        abortObserver: AbortNotifier()
      )

      guard let jsonData = json.data(using: .utf8) else {
        Issue.record("JSON is not valid UTF-8")
        return
      }
      let payload = try snakeDecoder.decode(ReadImagePayload.self, from: jsonData)
      #expect(payload.ok == true)
      #expect(payload.isImage == true)
      #expect(payload.mimeType == "image/png")
      #expect(payload.bytes == data.count)
      #expect(!(payload.base64?.isEmpty ?? true))
      #expect(Data(base64Encoded: payload.base64 ?? "") == data)
    }
  }

  @Test func readFileStillReadsTextFiles() async throws {
    let registry = ToolRegistry(tools: [ReadFileTool()])
    try await withTemporaryDirectory { dir in
      let fileURL = dir.appendingPathComponent("sample.txt")
      let body = "hello world"
      try body.write(to: fileURL, atomically: true, encoding: .utf8)

      let args = try jsonArguments(["path": fileURL.path])
      let json = try! await registry.run(
        name: "read_file",
        arguments: args,
        workingDirectory: ScribeFilePath("/tmp"),
        abortObserver: AbortNotifier()
      )
      let payload = try decodeRead(json)
      #expect(payload.ok == true)
      #expect(payload.content == body)
      #expect(payload.bytes == body.utf8.count)
    }
  }
}

private let snakeDecoder: JSONDecoder = {
  let d = JSONDecoder()
  d.keyDecodingStrategy = .convertFromSnakeCase
  return d
}()

private struct ReadImagePayload: Decodable {
  let ok: Bool
  let path: String?
  let isImage: Bool?
  let mimeType: String?
  let base64: String?
  let bytes: Int?
}
