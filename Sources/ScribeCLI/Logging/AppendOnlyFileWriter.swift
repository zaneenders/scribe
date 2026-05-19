import Foundation
import Synchronization

/// Mutex-protected append-only file writer for log files and `messages.jsonl`.
///
/// Creates parent directories and an empty file when missing, seeks to end on open,
/// and does not call `fsync` on every `append` (trace-level shell logging can emit
/// hundreds of lines per second; per-line fsync was a major CPU hotspot). Durability
/// is bounded by `close()` or `deinit`, which synchronizes and closes the handle.
final class AppendOnlyFileWriter: Sendable {
  private let state: Mutex<State?>

  private struct State {
    var handle: FileHandle
  }

  /// Opens `fileURL` for append. Throws if the file cannot be created or opened.
  init(fileURL: URL) throws {
    let url = fileURL.standardizedFileURL
    let parent = url.deletingLastPathComponent()
    if !FileManager.default.fileExists(atPath: parent.path) {
      try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    }
    if !FileManager.default.fileExists(atPath: url.path) {
      guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
        throw AppendOnlyFileError.couldNotCreateFile(url.path)
      }
    }
    let handle = try FileHandle(forUpdating: url)
    try handle.seekToEnd()
    self.state = Mutex(State(handle: handle))
  }

  func append(_ data: Data) throws {
    try state.withLock { stored in
      guard let stored else { throw AppendOnlyFileError.closed }
      try stored.handle.write(contentsOf: data)
    }
  }

  func close() {
    state.withLock { slot in
      guard let active = slot else { return }
      try? active.handle.synchronize()
      try? active.handle.close()
      slot = nil
    }
  }

  deinit {
    close()
  }
}

enum AppendOnlyFileError: Error, LocalizedError {
  case couldNotCreateFile(String)
  case closed

  var errorDescription: String? {
    switch self {
    case .couldNotCreateFile(let path):
      return "could not create file at \(path)"
    case .closed:
      return "append-only file writer is closed"
    }
  }
}
