import Foundation
import Synchronization

final class LockedDataWriter: Sendable {
  private let mutex = Mutex(())
  private let emit: @Sendable (Data) -> Void

  init(_ emit: @escaping @Sendable (Data) -> Void) {
    self.emit = emit
  }

  func write(_ data: Data) {
    mutex.withLock { _ in emit(data) }
  }
}
