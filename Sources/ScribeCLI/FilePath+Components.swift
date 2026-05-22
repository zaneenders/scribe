import SystemPackage

extension FilePath {
  /// Returns `self` with `component` appended as a single path segment.
  func appendingPathComponent(_ component: String) -> FilePath {
    var copy = self
    copy.append(component)
    return copy
  }
}
