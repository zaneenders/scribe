import SystemPackage

extension FilePath {

  public func appendingPathComponent(_ component: String) -> FilePath {
    var copy = self
    copy.append(component)
    return copy
  }
}
