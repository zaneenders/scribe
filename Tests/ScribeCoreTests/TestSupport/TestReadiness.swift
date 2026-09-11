import Foundation

/// One-shot, buffered readiness notification for async test doubles.
struct TestReadiness: Sendable {
  private let channel = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))

  func signal() {
    channel.continuation.yield(())
    channel.continuation.finish()
  }

  func wait() async throws {
    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask {
        for await _ in channel.stream { return }
        try Task.checkCancellation()
      }
      group.addTask {
        try await Task.sleep(for: .seconds(15))
        throw TestReadinessTimeout()
      }
      defer { group.cancelAll() }
      try await group.next()
    }
  }
}

private struct TestReadinessTimeout: Error, CustomStringConvertible {
  var description: String { "Test operation did not signal readiness within 15 seconds" }
}

/// A child process signals only after reaching the point under test.
struct ShellReadinessMarker: Sendable {
  let directory: URL
  let marker: URL

  init() throws {
    directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    marker = directory.appendingPathComponent("ready")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }

  var signalCommand: String {
    let quoted = marker.path.replacingOccurrences(of: "'", with: "'\"'\"'")
    return ": > '\(quoted)'"
  }

  func wait() async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(15))
    while !FileManager.default.fileExists(atPath: marker.path) {
      guard ContinuousClock.now < deadline else { throw TestReadinessTimeout() }
      try await Task.sleep(for: .milliseconds(10))
    }
  }

  func remove() {
    try? FileManager.default.removeItem(at: directory)
  }
}
