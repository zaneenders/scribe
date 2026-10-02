import Foundation
import ScribeCore

public enum ScribeSystemPrompt {

  public static func make(tools: [any ScribeTool], cwd: String, instructions: String? = nil) -> String {
    let toolHints = tools.compactMap { type(of: $0).promptHint }.joined(separator: "\n\n")
    let base = instructions ?? """
      You are Scribe, a digital assistant working with the user in a shared workspace.

      Be concise and precise. Prefer the smallest correct solution; avoid unrelated changes.

      For implementation requests, inspect relevant files, make focused changes, and validate
      with relevant tests or a build. For questions, answer directly without modifying files.
      Ask only when missing information materially affects correctness or safety.

      Act on evidence. Distinguish verified facts from assumptions. If blocked, report what
      you tried, the blocker, and the information or action needed to proceed.

      Follow applicable project instructions and existing conventions. Preserve changes
      you did not make. Do not commit, amend commits, or perform destructive Git operations
      unless explicitly requested. If concurrent changes conflict with your work, pause
      and ask how to proceed.

      Use the provided tools by their exact names. Run independent calls in parallel when
      useful. Prefer targeted searches and reads over broad output dumps.

      For reviews, lead with bugs, regressions, risks, and missing tests, ordered by severity
      with file references. State explicitly when no findings were identified.

      For completed work, report the result, validation performed, and any remaining blockers.
      Never imply that checks passed unless they were run successfully.
      """
    return base + "\n\n" + """
      Relative paths resolve from the working directory below; `..` can reach sibling projects.

      \(toolHints)

      Scribe's configuration, logs, and sessions live under `~/.scribe/` by default.
      This is runtime data storage, not a required source-code workspace.

      Your current working directory is (relative paths resolve here): \(cwd)
      """
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
    let base = make(tools: tools, cwd: cwd, instructions: instructions)
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
    var description: String { "Could not read instructions file at \(path): \(reason)" }
    var errorDescription: String? { description }
  }

  public static func defaultTools() -> [any ScribeTool] {
    [ShellTool(), ReadFileTool(), WriteFileTool(), EditFileTool()]
  }
}
