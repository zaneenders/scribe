import Chroma
import Dispatch
import HeadlessBackend
import Testing

@testable import ScribeBlocks

@MainActor
struct ObservationTests {
  private func drainChanges() async {
    await withCheckedContinuation { continuation in
      DispatchQueue.main.async { continuation.resume() }
    }
  }

  @Test func storeChangesRequestRedrawAndRearmAfterRendering() async {
    let store = ScribeMacStore.shared
    let previousError = store.lastError
    defer { store.lastError = previousError }
    store.lastError = "Before"

    let renderer = HeadlessRenderer()
    renderer.content = DeferredBlock { Text(store.lastError ?? "") }
    var redraws = 0
    renderer.onRedrawRequested = { redraws += 1 }
    defer { renderer.close() }
    let initial = renderer.render()

    store.lastError = "After"
    await drainChanges()
    #expect(redraws == 1)
    #expect(renderer.render() != initial)

    store.lastError = "Before"
    await drainChanges()
    #expect(redraws == 2)
    #expect(renderer.render() == initial)

    for index in 0..<100 {
      store.lastError = "Token \(index)"
    }
    await drainChanges()
    #expect(redraws == 3)
    #expect(renderer.render() != initial)

    store.lastError = "Pending at close"
    renderer.close()
    await drainChanges()
    #expect(redraws == 3)
    store.lastError = "After close"
    await drainChanges()
    #expect(redraws == 3)
  }
}
