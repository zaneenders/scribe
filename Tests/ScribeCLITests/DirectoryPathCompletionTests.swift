import Foundation
import SystemPackage
import Testing

@testable import ScribeKit

@Suite
struct DirectoryPathCompletionTests {
  @Test func resolveAbsoluteDirectory() throws {
    let tmp = FileManager.default.temporaryDirectory.path
    let result = DirectoryPathCompletion.resolve(input: tmp, relativeTo: "/")
    #expect(result.error == nil)
    #expect(result.path == URL(fileURLWithPath: tmp).standardizedFileURL.path)
  }

  @Test func resolveRelativeDirectory() throws {
    try withTemporaryDirectory { dir in
      let parent = dir.deletingLastPathComponent().path
      let name = dir.lastPathComponent
      let result = DirectoryPathCompletion.resolve(input: name, relativeTo: parent)
      #expect(result.error == nil)
      #expect(result.path == dir.path)
    }
  }

  @Test func resolveTildeHome() {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let result = DirectoryPathCompletion.resolve(input: "~", relativeTo: "/")
    #expect(result.error == nil)
    #expect(result.path == home)
  }

  @Test func resolveTildePath() throws {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let dir = URL(fileURLWithPath: home, isDirectory: true)
      .appendingPathComponent(".scribe-dir-complete-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let suffix = String(dir.path.dropFirst(home.count))
    let result = DirectoryPathCompletion.resolve(input: "~\(suffix)", relativeTo: "/")
    #expect(result.error == nil)
    #expect(result.path == dir.path)
  }

  @Test func resolveMissingPathFails() {
    let bogus = "/no/such/directory-\(UUID().uuidString)"
    let result = DirectoryPathCompletion.resolve(input: bogus, relativeTo: "/")
    #expect(result.path == nil)
    #expect(result.error?.contains("path does not exist") == true)
  }

  @Test func resolveFilePathFails() throws {
    try withTemporaryDirectory { dir in
      let file = dir.appendingPathComponent("file.txt")
      try "x".write(to: file, atomically: true, encoding: .utf8)
      let result = DirectoryPathCompletion.resolve(input: file.path, relativeTo: dir.path)
      #expect(result.path == nil)
      #expect(result.error?.contains("not a directory") == true)
    }
  }

  @Test func tabCompleteSingleMatchAddsSlash() throws {
    try withTemporaryDirectory { dir in
      let child = dir.appendingPathComponent("childdir", isDirectory: true)
      try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
      let parent = dir.path
      let result = DirectoryPathCompletion.tabComplete(input: "child", relativeTo: parent)
      #expect(result.text == "childdir/")
      #expect(result.matches == ["childdir"])
    }
  }

  @Test func tabCompleteMultipleMatchesExtendsPrefix() throws {
    try withTemporaryDirectory { dir in
      try FileManager.default.createDirectory(
        at: dir.appendingPathComponent("alpha-one", isDirectory: true),
        withIntermediateDirectories: true)
      try FileManager.default.createDirectory(
        at: dir.appendingPathComponent("alpha-two", isDirectory: true),
        withIntermediateDirectories: true)
      let result = DirectoryPathCompletion.tabComplete(input: "a", relativeTo: dir.path)
      #expect(result.text == "alpha-")
      #expect(result.matches.sorted() == ["alpha-one", "alpha-two"])
    }
  }

  @Test func tabCompleteAbsoluteTrailingSlashListsChildren() throws {
    try withTemporaryDirectory { dir in
      let child = dir.appendingPathComponent("nested", isDirectory: true)
      try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
      let input = dir.path + "/"
      let result = DirectoryPathCompletion.tabComplete(input: input, relativeTo: "/")
      #expect(result.matches.contains("nested"))
    }
  }
}

private func withTemporaryDirectory(
  _ body: (URL) throws -> Void
) throws {
  let dir = FileManager.default.temporaryDirectory
    .appendingPathComponent("scribe-dir-complete-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: dir) }
  try body(dir)
}
