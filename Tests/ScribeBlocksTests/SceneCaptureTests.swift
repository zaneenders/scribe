import Testing
@testable import ScribeBlocks

struct SceneCaptureTests {
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
