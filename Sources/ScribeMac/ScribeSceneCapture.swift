import Chroma
import Foundation
import Observation

@MainActor
@Observable
public final class ScribeSceneCapture {
  public static let shared = ScribeSceneCapture()
  private(set) var isEnabled = false
  private(set) var status = "Capture scene"
  private var pending = false
  private var saving = false
  private let directory: URL

  init(
    directory: URL = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".scribe/captures", isDirectory: true)
  ) {
    self.directory = directory
  }

  public func enable() -> FrameObserver {
    isEnabled = true
    return { [self] frame in observe(frame) }
  }

  func request() {
    guard isEnabled, !pending, !saving else { return }
    pending = true
    status = "Scene capture requested"
  }

  private func observe(_ frame: FrameObservation) {
    guard pending, !saving else { return }
    pending = false
    saving = true
    status = "Saving scene..."
    let directory = directory
    Task {
      let result = await Task.detached(priority: .utility) { () -> Result<URL, Error> in
        Result {
          try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
          let data = try SceneCapture.encode(frame)
          let url = directory.appendingPathComponent("scene-\(UUID().uuidString).chromacapture")
          guard
            FileManager.default.createFile(
              atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600])
          else { throw CocoaError(.fileWriteUnknown) }
          return url
        }
      }.value
      saving = false
      switch result {
      case .success(let url):
        status = "Scene saved — capture again"
        print("Scene snapshot saved (may contain private text/images): \(url.path)")
      case .failure(let error):
        status = "Scene capture failed: retry"
        print("Scene snapshot failed: \(error)")
      }
    }
  }
}
