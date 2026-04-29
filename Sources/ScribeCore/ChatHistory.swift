import ScribeLLM

public enum ChatHistory {
  /// Returns the newest assistant `content`, if present.
  public static func lastAssistantText(from messages: [Components.Schemas.ChatMessage]) -> String? {
    for message in messages.reversed() where message.role == .assistant {
      return message.content
    }
    return nil
  }
}
