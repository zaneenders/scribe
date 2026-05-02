import Foundation
import OpenAPIRuntime

/// OpenAI-style tool definitions (aligned with ``ToolRunner``).
public enum AgentTools {
  public static func all() -> [Components.Schemas.ChatTool] {
    OpenAIToolParameterSchema.all
  }
}

/// Builders for `ChatToolFunction.parameters` (OpenAPI object schemas as `OpenAPIObjectContainer`).
private enum OpenAIToolParameterSchema {
  static func asPayload(
    _ object: [String: (any Sendable)?]
  ) -> Components.Schemas.ChatToolFunction.ParametersPayload {
    let container =
      (try? OpenAPIObjectContainer(unvalidatedValue: object)) ?? OpenAPIObjectContainer()
    return .init(additionalProperties: container)
  }

  private static func stringProperty(description: String) -> [String: (any Sendable)?] {
    ["type": "string", "description": description]
  }

  private static let path = stringProperty(
    description: "Filesystem path (relative paths resolve against the process cwd)."
  )
  private static let content = stringProperty(description: "Full file contents.")
  private static let command = stringProperty(description: "Shell command to run (passed to /bin/sh -c).")
  private static let cwd = stringProperty(
    description:
      "Optional working directory for the command (relative paths resolve against the process cwd)."
  )
  private static let oldString = stringProperty(
    description: "Exact text to replace; must match exactly one place."
  )
  private static let newString = stringProperty(description: "Replacement text.")

  /// Line-based, 1-indexed start position for `read_file` pagination.
  private static let readFileOffset: [String: (any Sendable)?] = [
    "type": "integer",
    "description":
      "1-indexed line number to start reading from. Omit (or pass 1) to start at the top. "
      + "Use the previous call's `end_line + 1` to read the next page of a large file.",
  ]
  /// Maximum number of lines to return; defaults to 2000 server-side when omitted.
  private static let readFileLimit: [String: (any Sendable)?] = [
    "type": "integer",
    "description":
      "Maximum number of lines to return (default 2000). Pass a smaller value when only a "
      + "section is needed; pass `0` to read to end of file. Response includes `total_lines`, "
      + "`start_line`, `end_line`, and `truncated` so you can tell whether to fetch another page.",
  ]

  static var all: [Components.Schemas.ChatTool] {
    [
      .init(
        _type: .function,
        function: .init(
          name: "shell",
          description: "Run a command via /bin/sh -c.",
          parameters: asPayload([
            "type": "object",
            "properties": [
              "command": command,
              "cwd": cwd,
            ] as [String: (any Sendable)?],
            "required": ["command"] as (any Sendable)?,
          ])
        )
      ),
      .init(
        _type: .function,
        function: .init(
          name: "read_file",
          description:
            "Read a UTF-8 file at the given path (relative paths resolve against the process cwd). "
            + "Supports line-based pagination via `offset` and `limit` so very large files can be "
            + "fetched in sections without bloating the conversation history. The result includes "
            + "`bytes`, `total_lines`, `start_line`, `end_line`, and `truncated` so you can decide "
            + "whether to request another page (`offset = previous end_line + 1`).",
          parameters: asPayload([
            "type": "object",
            "properties": [
              "path": path,
              "offset": readFileOffset,
              "limit": readFileLimit,
            ] as [String: (any Sendable)?],
            "required": ["path"] as (any Sendable)?,
          ])
        )
      ),
      .init(
        _type: .function,
        function: .init(
          name: "write_file",
          description: "Create or overwrite a file (parent directory must exist).",
          parameters: asPayload([
            "type": "object",
            "properties": [
              "path": path,
              "content": content,
            ] as [String: (any Sendable)?],
            "required": ["path", "content"] as (any Sendable)?,
          ])
        )
      ),
      .init(
        _type: .function,
        function: .init(
          name: "edit_file",
          description: "Replace one unique occurrence of old_string with new_string.",
          parameters: asPayload([
            "type": "object",
            "properties": [
              "path": path,
              "old_string": oldString,
              "new_string": newString,
            ] as [String: (any Sendable)?],
            "required": ["path", "old_string", "new_string"] as (any Sendable)?,
          ])
        )
      ),
    ]
  }
}
