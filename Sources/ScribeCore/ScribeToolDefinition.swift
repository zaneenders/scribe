import Foundation
import OpenAPIRuntime
import ScribeLLM

// MARK: - Tool definition

/// A tool definition that can be constructed without importing ScribeLLM.
///
/// Use this in CLI or host code to register additional tools beyond the built-in
/// set.  Each definition pairs with a ``ScribeTool`` implementation registered
/// in the ``ToolRegistry`` passed to the coordinator.
public struct ScribeToolDefinition: Sendable {
  public struct Parameter: Sendable {
    public let name: String
    /// JSON Schema type string: `"string"`, `"integer"`, `"boolean"`, etc.
    public let type: String
    public let description: String
    public let required: Bool

    public init(name: String, type: String, description: String, required: Bool = true) {
      self.name = name
      self.type = type
      self.description = description
      self.required = required
    }
  }

  public let name: String
  public let description: String
  public let parameters: [Parameter]
  /// Optional hint injected into the system prompt (e.g. pagination guidance).
  public let promptHint: String?

  public init(
    name: String, description: String, parameters: [Parameter] = [],
    promptHint: String? = nil
  ) {
    self.name = name
    self.description = description
    self.parameters = parameters
    self.promptHint = promptHint
  }
}

// MARK: - Built-in definitions

extension ScribeToolDefinition {
  /// All four built-in tool definitions.
  public static let builtIn: [ScribeToolDefinition] = [.shell, .readFile, .writeFile, .editFile]

  public static let shell = ScribeToolDefinition(
    name: "shell",
    description: "Run a command via /bin/sh -c.",
    parameters: [
      Parameter(name: "command", type: "string",
                description: "Shell command to run (passed to /bin/sh -c).", required: true),
      Parameter(name: "cwd", type: "string",
                description: "Optional working directory for the command (relative paths resolve against the process cwd).",
                required: false),
    ])

  public static let readFile = ScribeToolDefinition(
    name: "read_file",
    description:
      "Read a UTF-8 file at the given path (relative paths resolve against the process cwd). "
      + "Supports line-based pagination via `offset` and `limit` so very large files can be "
      + "fetched in sections without bloating the conversation history. The result includes "
      + "`bytes`, `total_lines`, `start_line`, `end_line`, and `truncated` so you can decide "
      + "whether to request another page (`offset = previous end_line + 1`).",
    parameters: [
      Parameter(name: "path", type: "string",
                description: "Filesystem path (relative paths resolve against the process cwd).",
                required: true),
      Parameter(name: "offset", type: "integer",
                description:
                  "1-indexed line number to start reading from. Omit (or pass 1) to start at the top. "
                  + "Use the previous call's `end_line + 1` to read the next page of a large file.",
                required: false),
      Parameter(name: "limit", type: "integer",
                description:
                  "Maximum number of lines to return (default 2000). Pass a smaller value when only a "
                  + "section is needed; pass `0` to read to end of file. Response includes `total_lines`, "
                  + "`start_line`, `end_line`, and `truncated` so you can tell whether to fetch another page.",
                required: false),
    ],
    promptHint:
      "For `read_file`, prefer paginating large files: pass `offset` (1-indexed start line) "
      + "and `limit` (max lines, default 2000) and use the returned `end_line` + 1 as the "
      + "next `offset` if `truncated` is true. This keeps the conversation history small."
  )

  public static let writeFile = ScribeToolDefinition(
    name: "write_file",
    description: "Create or overwrite a file (parent directory must exist).",
    parameters: [
      Parameter(name: "path", type: "string",
                description: "Filesystem path (relative paths resolve against the process cwd).",
                required: true),
      Parameter(name: "content", type: "string",
                description: "Full file contents.", required: true),
    ])

  public static let editFile = ScribeToolDefinition(
    name: "edit_file",
    description: "Replace one unique occurrence of old_string with new_string.",
    parameters: [
      Parameter(name: "path", type: "string",
                description: "Filesystem path (relative paths resolve against the process cwd).",
                required: true),
      Parameter(name: "old_string", type: "string",
                description: "Exact text to replace; must match exactly one place.",
                required: true),
      Parameter(name: "new_string", type: "string",
                description: "Replacement text.", required: true),
    ])
}

// MARK: - ScribeToolDefinition → ChatTool conversion

extension ScribeToolDefinition {
  func toChatTool() -> Components.Schemas.ChatTool {
    var props: [String: (any Sendable)?] = [:]
    var required: [String] = []
    for p in parameters {
      props[p.name] = ["type": p.type, "description": p.description] as [String: (any Sendable)?]
      if p.required { required.append(p.name) }
    }
    let payload: [String: (any Sendable)?] = [
      "type": "object",
      "properties": props,
      "required": required,
    ]
    let container =
      (try? OpenAPIObjectContainer(unvalidatedValue: payload)) ?? OpenAPIObjectContainer()
    return Components.Schemas.ChatTool(
      _type: .function,
      function: .init(
        name: name,
        description: description,
        parameters: .init(additionalProperties: container)
      )
    )
  }
}
