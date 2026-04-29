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
            "Read a UTF-8 file at the given path (relative paths resolve against the process cwd).",
          parameters: asPayload([
            "type": "object",
            "properties": [
              "path": path
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
