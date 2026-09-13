import Foundation
import Testing

@testable import ScribeCore

struct OutputDrainDeadlineTests {
  private enum DrainFailure: Error { case failed }

  @Test func completedDrainPreservesByteCounts() async throws {
    let drain = Task<DrainBytes, Error> { DrainBytes(out: 42, err: 7) }
    let result = await OutputCapture.awaitDrainWithDeadline(
      drainTask: drain, deadlineMs: 5_000, shellID: UUID(), logger: toolRunnerTestLogger)
    let bytes = try #require(result)
    #expect(bytes.out == 42)
    #expect(bytes.err == 7)
    #expect(!drain.isCancelled)
  }

  @Test func failedDrainReturnsNil() async {
    let drain = Task<DrainBytes, Error> { throw DrainFailure.failed }
    let result = await OutputCapture.awaitDrainWithDeadline(
      drainTask: drain, deadlineMs: 5_000, shellID: UUID(), logger: toolRunnerTestLogger)
    #expect(result == nil)
  }

  @Test(.timeLimit(.minutes(1))) func deadlineDoesNotJoinAnUncooperativeDrain() async {
    // This gate deliberately ignores cancellation. Release it only AFTER the
    // deadline returns: a task-group-based race would hang waiting for it.
    let (gate, release) = AsyncStream<Void>.makeStream()
    let drain = Task<DrainBytes, Error> {
      await withTaskCancellationShield {
        for await _ in gate {}
        return DrainBytes(out: 1, err: 2)
      }
    }
    defer {
      release.finish()
      _ = await drain.result
    }
    let start = ContinuousClock.now
    let result = await OutputCapture.awaitDrainWithDeadline(
      drainTask: drain, deadlineMs: 20, shellID: UUID(), logger: toolRunnerTestLogger)
    #expect(result == nil)
    #expect(drain.isCancelled)
    #expect(start.duration(to: .now) < .seconds(5))
  }

  @Test func cancelledCallerStillWaitsForSuccessfulCleanup() async throws {
    // Cancel before entering the helper so an unshielded AsyncStream iterator
    // would return nil immediately, rather than observing the drain result.
    let caller = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      #expect(Task.isCancelled)
      let drain = Task.detached { () throws -> DrainBytes in
        try await Task.sleep(for: .milliseconds(20))
        return DrainBytes(out: 12, err: 3)
      }
      let result = await OutputCapture.awaitDrainWithDeadline(
        drainTask: drain, deadlineMs: 5_000, shellID: UUID(), logger: toolRunnerTestLogger)
      #expect(Task.isCancelled)
      return result
    }
    let bytes = try #require(await caller.value)
    #expect(bytes.out == 12)
    #expect(bytes.err == 3)
  }
}
