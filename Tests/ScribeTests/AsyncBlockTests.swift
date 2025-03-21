import Testing

@testable import Demo
@testable import Scribe

// Helper extension to view state of the object.
extension AsyncUpdateStateUpdate {
  var modifiedBlock: Modified<String> {
    self.component as! Modified<String>
  }
  var value: String {
    modifiedBlock.wrapped
  }
}

@MainActor  // UI Block test run on main thread.
@Suite("Async Block Tests")
struct AsyncBlockTests {

  let firstPause = AsyncUpdateStateUpdate.delay / 2
  let secondPause = AsyncUpdateStateUpdate.delay

  @Test func asyncBlockTest() async throws {
    let block = AsyncUpdateStateUpdate()
    var container = BlockContainer(block)

    #expect(block.value == "ready")
    container.action(.lowercaseL)  // Move in
    container.action(.lowercaseI)  // Action
    #expect(block.value == "running")  // Task still running
    try await Task.sleep(for: .milliseconds(firstPause))
    #expect(block.value == "running")
    try await Task.sleep(for: .milliseconds(secondPause))
    #expect(block.value == "ready")  // Task completed
  }
}
