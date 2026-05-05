import SlateCore

enum SlateEdit {
  /// Runs the scratch buffer editor as a fullscreen Slate session.
  static func runFullscreen() async throws {
    try await Task { @MainActor in
      try await SlateEditHost().run()
    }.value
  }
}
