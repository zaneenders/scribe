import Chroma
import Foundation
import HeadlessBackend
import Testing
@testable import ScribeBlocks

struct SceneCaptureTests {
  @Test(arguments: [false, true]) @MainActor
  func saveCompletionRequestsRedraw(shouldFail: Bool) async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("scribe-capture-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let directory = root.appendingPathComponent("captures", isDirectory: true)
    if shouldFail {
      // A regular file at the destination makes directory creation fail deterministically.
      try Data().write(to: directory)
    }
    let capture = ScribeSceneCapture(directory: directory)
    let renderer = HeadlessRenderer()
    defer { renderer.close() }
    renderer.content = DeferredBlock { Text(capture.status) }
    renderer.frameObserver = capture.enable()
    capture.request()
    renderer.render()
    #expect(capture.status == "Saving scene...")

    // Rearm observation after the synchronous transition to Saving.
    renderer.render()
    var redraws = 0
    let expected = shouldFail ? "Scene capture failed: retry" : "Scene saved — capture again"
    renderer.onRedrawRequested = {
      if capture.status == expected { redraws += 1 }
    }
    let deadline = ContinuousClock.now + .seconds(5)
    while (capture.status != expected || redraws == 0), ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(capture.status == expected)
    #expect(redraws > 0)
    let frame = renderer.render()
    #expect(frame.commands.contains { command in
      if case .text(_, let text, _, _) = command { return text == expected }
      return false
    })
  }

  @Test @MainActor
  func captureRequiresHostAndCoalescesRequests() {
    let capture = ScribeSceneCapture()
    capture.request()
    #expect(!capture.isEnabled)
    #expect(capture.status == "Capture scene")
    _ = capture.enable()
    #expect(capture.isEnabled)
    capture.request()
    capture.request()
    #expect(capture.status == "Scene capture requested")
  }
}
