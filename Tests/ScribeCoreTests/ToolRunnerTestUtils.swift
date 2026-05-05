import Foundation

struct ShellPayload: Decodable {
  let ok: Bool
  let exitCode: Int?
  let stdout: String?
  let stderr: String?
}

struct FailPayload: Decodable {
  let ok: Bool
  let error: String?
}

struct ReadPayload: Decodable {
  let ok: Bool
  let content: String?
  let path: String?
  let bytes: Int?
  let totalLines: Int?
  let startLine: Int?
  let endLine: Int?
  let truncated: Bool?
}

struct WritePayload: Decodable {
  let ok: Bool
  let written: Bool?
}

struct EditPayload: Decodable {
  let ok: Bool
  let replaced: Bool?
  let content: String?
}

enum ToolRunnerTestFailure: LocalizedError {
  case utf8DecodeFailed

  var errorDescription: String? {
    switch self {
    case .utf8DecodeFailed:
      return "not UTF-8"
    }
  }
}

private let snakeDecoder: JSONDecoder = {
  let d = JSONDecoder()
  d.keyDecodingStrategy = .convertFromSnakeCase
  return d
}()

func decodeShell(_ json: String) throws -> ShellPayload {
  guard let data = json.data(using: .utf8) else {
    throw ToolRunnerTestFailure.utf8DecodeFailed
  }
  return try snakeDecoder.decode(ShellPayload.self, from: data)
}

func decodeFail(_ json: String) throws -> FailPayload {
  guard let data = json.data(using: .utf8) else {
    throw ToolRunnerTestFailure.utf8DecodeFailed
  }
  return try snakeDecoder.decode(FailPayload.self, from: data)
}

func decodeRead(_ json: String) throws -> ReadPayload {
  guard let data = json.data(using: .utf8) else {
    throw ToolRunnerTestFailure.utf8DecodeFailed
  }
  return try snakeDecoder.decode(ReadPayload.self, from: data)
}

func decodeWrite(_ json: String) throws -> WritePayload {
  guard let data = json.data(using: .utf8) else {
    throw ToolRunnerTestFailure.utf8DecodeFailed
  }
  return try snakeDecoder.decode(WritePayload.self, from: data)
}

func decodeEdit(_ json: String) throws -> EditPayload {
  guard let data = json.data(using: .utf8) else {
    throw ToolRunnerTestFailure.utf8DecodeFailed
  }
  return try snakeDecoder.decode(EditPayload.self, from: data)
}

func jsonArguments(_ pairs: [String: Any]) throws -> String {
  let data = try JSONSerialization.data(withJSONObject: pairs, options: [])
  return String(decoding: data, as: UTF8.self)
}

func withTemporaryDirectory<T>(
  operation body: (URL) async throws -> T
) async throws -> T {
  let dir = FileManager.default.temporaryDirectory
    .appendingPathComponent(UUID().uuidString, isDirectory: true)
  try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: dir) }
  return try await body(dir)
}
