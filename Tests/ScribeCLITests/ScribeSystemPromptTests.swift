import Foundation
import ScribeKit
import SystemPackage
import Testing

struct ScribeSystemPromptTests {
  private func withPaths(_ body: (ScribePaths) throws -> Void) throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try body(ScribePaths(dataHome: FilePath(directory.path)))
  }

  @Test func missingAndBlankFilesPreserveBasePrompt() throws {
    try withPaths { paths in
      let base = ScribeSystemPrompt.make(tools: [], cwd: "/project")
      #expect(try ScribeSystemPrompt.load(tools: [], cwd: "/project", paths: paths) == base)
      try " \n\t".write(toFile: paths.systemPromptPath.string, atomically: true, encoding: .utf8)
      #expect(try ScribeSystemPrompt.load(tools: [], cwd: "/project", paths: paths) == base)
    }
  }

  @Test func appendsVerbatimFromConfiguredDataHome() throws {
    try withPaths { paths in
      let text = "# Preferences\n\n- Use Swift.\n"
      try text.write(toFile: paths.systemPromptPath.string, atomically: true, encoding: .utf8)
      let prompt = try ScribeSystemPrompt.load(tools: [], cwd: "/project", paths: paths)
      #expect(prompt.hasPrefix(ScribeSystemPrompt.make(tools: [], cwd: "/project")))
      #expect(prompt.hasSuffix("# Additional user-configured instructions\n\n" + text))
    }
  }

  @Test func invalidUTF8AndDirectoryReportPath() throws {
    try withPaths { paths in
      let url = URL(fileURLWithPath: paths.systemPromptPath.string)
      try Data([0xff]).write(to: url)
      for _ in 0..<2 {
        do {
          _ = try ScribeSystemPrompt.load(tools: [], cwd: "/project", paths: paths)
          Issue.record("Expected prompt file error")
        } catch {
          #expect(String(describing: error).contains(url.path))
        }
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
      }
    }
  }
}
