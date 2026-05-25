import Foundation
import ScribeLLM

/// Token usage snapshot emitted by the model provider, surfaced through the
/// public ``AgentEvent`` and ``TokenTracker`` APIs.
///
/// Mirrors the OpenAI chat-completions "usage" payload but is owned by
/// `ScribeCore`, so embedders never see the OpenAPI-generated
/// `Components.Schemas.CompletionUsage` type. Many OpenAI-compatible
/// servers omit subsets of these fields — every property is optional.
public struct ScribeUsage: Sendable, Hashable {
  /// Tokens consumed by the prompt for this response.
  public var promptTokens: Int?
  /// Tokens produced in the assistant response.
  public var completionTokens: Int?
  /// `promptTokens + completionTokens`, when reported by the server. Some
  /// providers omit this and require the caller to sum the two above.
  public var totalTokens: Int?
  /// Subset of `completionTokens` spent on hidden reasoning, when reported.
  public var reasoningTokens: Int?
  /// Subset of `promptTokens` served from a prompt cache, when reported.
  public var cachedPromptTokens: Int?

  public init(
    promptTokens: Int? = nil,
    completionTokens: Int? = nil,
    totalTokens: Int? = nil,
    reasoningTokens: Int? = nil,
    cachedPromptTokens: Int? = nil
  ) {
    self.promptTokens = promptTokens
    self.completionTokens = completionTokens
    self.totalTokens = totalTokens
    self.reasoningTokens = reasoningTokens
    self.cachedPromptTokens = cachedPromptTokens
  }
}


extension ScribeUsage {
  /// Build a ``ScribeUsage`` from the OpenAPI-generated wire type. Kept
  /// `package`-internal so the wire shape does not leak through the public
  /// API of `ScribeCore`.
  package init(_ usage: Components.Schemas.CompletionUsage) {
    self.promptTokens = usage.promptTokens
    self.completionTokens = usage.completionTokens
    self.totalTokens = usage.totalTokens
    self.reasoningTokens = usage.completionTokensDetails?.reasoningTokens
    self.cachedPromptTokens = usage.promptTokensDetails?.cachedTokens
  }
}
