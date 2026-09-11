#if os(macOS)
import Foundation
import Testing
@testable import ScribeMac

@Suite(.serialized)
struct OwnedBackendTests {
  private func start(_ owner: OwnedBackend, script: String, timeout: TimeInterval = 2) throws -> Int {
    try owner.start(executableURL: URL(fileURLWithPath: "/bin/sh"),
                    arguments: ["-c", script], timeout: timeout)
  }

  @Test func readinessAndNormalClosure() throws {
    let owner = OwnedBackend()
    defer { owner.stop() }
    #expect(try start(owner, script: "printf '12345\\n'; cat >/dev/null") == 12345)
    #expect(owner.process.isRunning)
    owner.stop()
    #expect(!owner.process.isRunning)
    #expect(owner.process.terminationStatus == 0)
    owner.stop() // idempotent
  }

  @Test(arguments: ["exit 7", "printf 'oops\\n'", "printf '65536\\n'", "printf '123456'", "printf '0\\n'"])
  func startupFailure(script: String) {
    let owner = OwnedBackend()
    defer { owner.stop() }
    #expect(throws: (any Error).self) { try start(owner, script: script) }
  }

  @Test func startupTimeoutAndForcedCleanup() {
    let owner = OwnedBackend()
    defer { owner.stop() }
    #expect(throws: (any Error).self) {
      try start(owner, script: "exec sleep 30", timeout: 0.1)
    }
    owner.stop()
    #expect(!owner.process.isRunning)
  }

  @Test func concurrentStopIsIdempotent() throws {
    let owner = OwnedBackend()
    defer { owner.stop() }
    #expect(try start(owner, script: "printf '12345\\n'; cat >/dev/null") == 12345)
    // stop() blocks while reaping the child; do not exhaust Swift's cooperative
    // executor with lock waiters while Foundation delivers process termination.
    DispatchQueue.concurrentPerform(iterations: 8) { _ in owner.stop() }
    #expect(!owner.process.isRunning)
    #expect(owner.process.terminationStatus == 0)
  }

  @Test func backendDeathAfterReadiness() throws {
    let owner = OwnedBackend()
    defer { owner.stop() }
    #expect(try start(owner, script: "printf '12345\\n'; exit 9") == 12345)
    owner.process.waitUntilExit()
    #expect(owner.process.terminationStatus == 9)
  }
}
#endif
