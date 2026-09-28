import Foundation
import ScribeCore

public enum ScribeSystemPrompt {

  public static func make(tools: [any ScribeTool], cwd: String, additionalInstructions: String = "") -> String {
    let toolHints = tools.compactMap { type(of: $0).promptHint }.joined(separator: "\n\n")
    let base = """
      You are Scribe, a digital assistant.

      YOU ARE TO BE AS CONCISE AND PRECISE AS POSSIBLE, ITERATION OVER PERFECTION.

      Inspect available files and tools before asking the user.

      Act on evidence; when blocked, explain what you tried and ask for the missing information.
      Preserve unrelated work. Do not perform destructive Git operations unless explicitly requested.
      Use the provided tools by their exact names. Run independent calls in parallel when useful.
      Relative paths resolve from the working directory below; `..` can reach sibling projects.

      \(toolHints)

      Scribe's configuration, logs, and sessions live under `~/.scribe/` by default.
      This is runtime data storage, not a required source-code workspace.

      Your current working directory is (relative paths resolve here): \(cwd)
      """
    guard !additionalInstructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return base }
    return base + "\n\n# Additional user-configured instructions\n\n" + additionalInstructions
  }

  public static func load(tools: [any ScribeTool], cwd: String, paths: ScribePaths) throws -> String {
    let url = URL(fileURLWithPath: paths.systemPromptPath.string)
    let instructions = try readInstructions(at: url)
    let directory = URL(fileURLWithPath: cwd, isDirectory: true).standardizedFileURL
    var directories: [URL] = []
    var current = directory
    while true {
      directories.append(current)
      let parent = current.deletingLastPathComponent()
      if parent.path == current.path { break }
      current = parent
    }
    let projectInstructions = try directories.reversed().compactMap { directory -> String? in
      let file = directory.appendingPathComponent("AGENTS.md")
      return try readInstructions(at: file).map { "# \(file.path)\n\n\($0)" }
    }
    let base = make(tools: tools, cwd: cwd, additionalInstructions: instructions ?? "")
    guard !projectInstructions.isEmpty else { return base }
    return base + "\n\n# Project instructions\n\n" + projectInstructions.joined(separator: "\n\n")
  }

  private static func readInstructions(at url: URL) throws -> String? {
    do {
      return try String(contentsOf: url, encoding: .utf8)
    } catch CocoaError.fileReadNoSuchFile {
      return nil
    } catch {
      throw PromptFileError(path: url.path, reason: String(describing: error))
    }
  }

  private struct PromptFileError: LocalizedError, CustomStringConvertible {
    let path: String
    let reason: String
    var description: String { "Could not read system prompt appendix at \(path): \(reason)" }
    var errorDescription: String? { description }
  }

  public static func defaultTools() -> [any ScribeTool] {
    [ShellTool(), ReadFileTool(), WriteFileTool(), EditFileTool()]
  }
}
