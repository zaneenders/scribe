import Foundation

func withTemporaryDirectory<T>(
  _ body: (URL) throws -> T
) throws -> T {
  let dir = FileManager.default.temporaryDirectory
    .appendingPathComponent(UUID().uuidString, isDirectory: true)
  try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: dir) }
  return try body(dir)
}

func withTemporaryDirectory<T>(
  _ body: (URL) async throws -> T
) async throws -> T {
  let dir = FileManager.default.temporaryDirectory
    .appendingPathComponent(UUID().uuidString, isDirectory: true)
  try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: dir) }
  return try await body(dir)
}
