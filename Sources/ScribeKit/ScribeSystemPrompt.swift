import Foundation
import ScribeComputerUse
import ScribeCore

/// Builds the system prompt every Scribe front-end (CLI, macOS app) shares.
public enum ScribeSystemPrompt {

  /// Pure composition; file loading happens only when creating a new session.
  public static func make(tools: [any ScribeTool], cwd: String, additionalInstructions: String = "") -> String {
    let toolHints = tools.compactMap { type(of: $0).promptHint }.joined(separator: "\n\n")
    let base = """
      You are Scribe, a coding agent.

      Inspect available files and tools before asking the user. Act on evidence; when blocked, explain what you tried and ask for the missing information.
      Preserve unrelated work. Do not perform destructive Git operations unless explicitly requested.
      Use the provided tools by their exact names. Run independent calls in parallel when useful.
      Relative paths resolve from the working directory below; `..` can reach sibling projects.

      \(toolHints)

      Current working directory: \(cwd)
      """
    guard !additionalInstructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return base }
    return base + "\n\n# Additional user-configured instructions\n\n" + additionalInstructions
  }

  /// Called only for new sessions. The combined prompt is persisted once.
  public static func load(tools: [any ScribeTool], cwd: String, paths: ScribePaths) throws -> String {
    let url = URL(fileURLWithPath: paths.systemPromptPath.string)
    let instructions: String
    do {
      instructions = try String(contentsOf: url, encoding: .utf8)
    } catch CocoaError.fileReadNoSuchFile {
      return make(tools: tools, cwd: cwd)
    } catch {
      throw PromptFileError(path: url.path, reason: String(describing: error))
    }
    return make(tools: tools, cwd: cwd, additionalInstructions: instructions)
  }

  private struct PromptFileError: LocalizedError, CustomStringConvertible {
    let path: String
    let reason: String
    var description: String { "Could not read system prompt appendix at \(path): \(reason)" }
    var errorDescription: String? { description }
  }

  /// The default tool set every front-end offers the agent.
  public static func defaultTools() -> [any ScribeTool] {
    [ShellTool(), ReadFileTool(), WriteFileTool(), EditFileTool()] + ComputerUseTools.make()
  }
}
