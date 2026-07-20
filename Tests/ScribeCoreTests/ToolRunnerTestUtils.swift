import Foundation
import Logging
import Synchronization

@testable import ScribeCore

let toolRunnerTestLogger = Logger(label: "test.tool-runner")

struct ShellPayload: Decodable {
  let ok: Bool
  let exitCode: Int?
  let stdoutFile: String?
  let stderrFile: String?
  let pid: Int?
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
  let truncationReason: String?
  let contentBytes: Int?
  let contentCharacters: Int?
  let maxContentBytes: Int?
  let maxContentCharacters: Int?
  let byteOffset: Int?
}

struct WritePayload: Decodable {
  let ok: Bool
  let written: Bool?
}

struct EditPayload: Decodable {
  let ok: Bool
  let replaced: Bool?
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

/// Creates a unique temporary directory, passes it to `body`, and removes it afterward.
/// Cleanup is installed immediately before the body runs so the directory is always
/// removed even if the body throws.
func withTemporaryDirectory<T>(
  _ body: (URL) throws -> T
) throws -> T {
  let dir = FileManager.default.temporaryDirectory
    .appendingPathComponent(UUID().uuidString, isDirectory: true)
  try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: dir) }
  return try body(dir)
}

/// Async variant of `withTemporaryDirectory`.
func withTemporaryDirectory<T>(
  _ body: (URL) async throws -> T
) async throws -> T {
  let dir = FileManager.default.temporaryDirectory
    .appendingPathComponent(UUID().uuidString, isDirectory: true)
  try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: dir) }
  return try await body(dir)
}

final class AbortState: @unchecked Sendable {
  var value = false
  func set(_ newValue: Bool) { value = newValue }
}

final class CountingAbortObserver: AbortObserver, @unchecked Sendable {
  let counter = Atomic<Int>(0)
  private let triggerAt: Int

  init(triggerAt: Int) {
    self.triggerAt = triggerAt
  }

  func isAborted() -> Bool {
    let c = counter.load(ordering: .sequentiallyConsistent)
    counter.store(c + 1, ordering: .sequentiallyConsistent)
    return c >= triggerAt
  }

  func signals() -> AsyncStream<Void> {
    AsyncStream { continuation in continuation.finish() }
  }
}
