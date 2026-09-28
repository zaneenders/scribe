import Foundation
import ScribeKit
import SystemPackage
import Testing

struct ScribeSystemPromptTests {
  @Test func defaultToolsAreShellAndFileTools() {
    let names = ScribeSystemPrompt.defaultTools().map { type(of: $0).name }
    #expect(names == ["shell", "read_file", "write_file", "edit_file"])
  }

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

  @Test func loadsProjectInstructionsFromAncestorsInOrder() throws {
    try withPaths { paths in
      let root = URL(fileURLWithPath: paths.dataHome.string).appendingPathComponent("project")
      let child = root.appendingPathComponent("Sources")
      try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
      try "Root rules".write(to: root.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)
      try "Source rules".write(to: child.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)
      try "Personal rules".write(toFile: paths.systemPromptPath.string, atomically: true, encoding: .utf8)

      let prompt = try ScribeSystemPrompt.load(tools: [], cwd: child.path, paths: paths)
      #expect(prompt.contains("# Additional user-configured instructions\n\nPersonal rules"))
      #expect(prompt.contains("# \(root.path)/AGENTS.md\n\nRoot rules"))
      #expect(prompt.contains("# \(child.path)/AGENTS.md\n\nSource rules"))
      #expect(prompt.range(of: "Root rules")!.lowerBound < prompt.range(of: "Source rules")!.lowerBound)
    }
  }

  @Test func invalidProjectInstructionsReportPath() throws {
    try withPaths { paths in
      let project = URL(fileURLWithPath: paths.dataHome.string).appendingPathComponent("project")
      try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
      let file = project.appendingPathComponent("AGENTS.md")
      try Data([0xff]).write(to: file)
      do {
        _ = try ScribeSystemPrompt.load(tools: [], cwd: project.path, paths: paths)
        Issue.record("Expected project instructions error")
      } catch {
        #expect(error.localizedDescription.contains(file.path))
      }
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
          #expect(error.localizedDescription == String(describing: error))
        }
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
      }
    }
  }
}
