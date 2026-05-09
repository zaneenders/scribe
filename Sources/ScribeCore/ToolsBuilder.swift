// MARK: - ToolsBuilder

/// A result-builder that composes an array of ``ScribeTool`` values.
///
/// Use ``ToolsBuilder`` to declare tool sets with a concise DSL.  You can mix
/// named tool types and ``InlineTool`` instances, and even use control-flow
/// (`if`, `for`, `switch`) inside the block.
///
/// ```swift
/// let tools = Tools {
///   ShellTool()
///   ReadFileTool()
///   WriteFileTool()
///   EditFileTool()
/// }
/// ```
///
/// You can also define inline tools without a separate type:
///
/// ```swift
/// let tools = Tools {
///   ShellTool()
///   ReadFileTool()
///
///   InlineTool(
///     name: "grep_code",
///     description: "Search code with ripgrep.",
///     parameters: [
///       ScribeToolParameter(name: "pattern", type: .string,
///                           description: "Regex pattern to search for.")
///     ]
///   ) { args in
///     // … run ripgrep …
///     struct Result: Encodable { let ok = true; let matches: [String] }
///     return Result(matches: [])
///   }
/// }
/// ```
@resultBuilder
public enum ToolsBuilder {
  public static func buildBlock(_ components: [any ScribeTool]...) -> [any ScribeTool] {
    components.flatMap { $0 }
  }

  public static func buildExpression(_ expression: any ScribeTool) -> [any ScribeTool] {
    [expression]
  }

  public static func buildOptional(_ component: [any ScribeTool]?) -> [any ScribeTool] {
    component ?? []
  }

  public static func buildEither(first component: [any ScribeTool]) -> [any ScribeTool] {
    component
  }

  public static func buildEither(second component: [any ScribeTool]) -> [any ScribeTool] {
    component
  }

  public static func buildArray(_ components: [[any ScribeTool]]) -> [any ScribeTool] {
    components.flatMap { $0 }
  }
}

/// Compose an array of ``ScribeTool`` values using ``ToolsBuilder`` syntax.
///
/// This free function is the entry point for the result-builder DSL:
///
/// ```swift
/// let tools = Tools {
///   ShellTool()
///   ReadFileTool()
/// }
/// ```
public func Tools(
  @ToolsBuilder _ builder: () -> [any ScribeTool]
) -> [any ScribeTool] {
  builder()
}
