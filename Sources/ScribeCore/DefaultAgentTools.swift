import Foundation
import ScribeLLM

/// Conversions from `ScribeTool` types to the `ChatTool` array the LLM sees
/// via the OpenAI-compatible API.
public enum DefaultAgentTools {

  /// Converts tool instances to the `ChatTool` array the LLM sees.
  public static func chatTools(from tools: [any ScribeTool]) -> [Components.Schemas.ChatTool] {
    tools.map { type(of: $0).toChatTool() }
  }
}
