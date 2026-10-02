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

  @Test func missingFileUsesInlinePrompt() throws {
    try withPaths { paths in
      let base = ScribeSystemPrompt.make(tools: [], cwd: "/project")
      let prompt = try ScribeSystemPrompt.load(tools: [], cwd: "/project", paths: paths)
      #expect(prompt == base)
      #expect(prompt.contains("You are Scribe"))
    }
  }

  @Test func existingBlankFileOverridesInlinePrompt() throws {
    try withPaths { paths in
      for text in ["", " \n\t"] {
        try text.write(toFile: paths.systemPromptPath.string, atomically: true, encoding: .utf8)
        let prompt = try ScribeSystemPrompt.load(tools: [], cwd: "/project", paths: paths)
        #expect(prompt.hasPrefix(text + "\n\n"))
        #expect(!prompt.contains("You are Scribe"))
        #expect(prompt.contains("Your current working directory"))
      }
    }
  }

  @Test func replacesInlinePromptAndPreservesRuntimeContext() throws {
    try withPaths { paths in
      let text = "# Preferences\n\n- Use Swift.\n"
      try text.write(toFile: paths.systemPromptPath.string, atomically: true, encoding: .utf8)
      let tools = ScribeSystemPrompt.defaultTools()
      let prompt = try ScribeSystemPrompt.load(tools: tools, cwd: "/project", paths: paths)
      #expect(prompt.hasPrefix(text + "\n\n"))
      #expect(!prompt.contains("You are Scribe"))
      #expect(prompt.contains("Your current working directory is (relative paths resolve here): /project"))
      #expect(prompt.contains("~/.scribe/"))
      for tool in tools {
        if let hint = type(of: tool).promptHint {
          #expect(prompt.contains(hint))
        }
      }
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
      #expect(prompt.hasPrefix("Personal rules\n\n"))
      #expect(!prompt.contains("You are Scribe"))
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
