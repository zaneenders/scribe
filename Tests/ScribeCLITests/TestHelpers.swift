import Foundation

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
