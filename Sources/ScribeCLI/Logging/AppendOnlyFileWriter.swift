import Foundation
import ScribeCore
import SystemPackage
import Synchronization

final class AppendOnlyFileWriter: Sendable {
  private let fd: Mutex<FileDescriptor?>

  init(filePath: FilePath) throws {
    try Self.ensureParentDirectory(for: filePath)
    let descriptor = try FileDescriptor.open(
      filePath,
      .writeOnly,
      options: [.create, .append],
      permissions: .ownerReadWrite
    )
    self.fd = Mutex(descriptor)
  }

  func append(_ data: Data) throws {
    try fd.withLock { slot in
      guard let descriptor = slot else { throw AppendOnlyFileError.closed }
      try descriptor.writeAll(data)
    }
  }

  func close() {
    fd.withLock { slot in
      guard slot != nil else { return }
      try? slot!.close()
      slot = nil
    }
  }

  deinit {
    close()
  }

  private static func ensureParentDirectory(for path: FilePath) throws {
    let parent = path.removingLastComponent()
    guard !parent.string.isEmpty else { return }
    try createDirectoryWithIntermediates(parent)
  }
}

enum AppendOnlyFileError: Error, LocalizedError {
  case closed

  var errorDescription: String? {
    switch self {
    case .closed:
      return "append-only file writer is closed"
    }
  }
}
