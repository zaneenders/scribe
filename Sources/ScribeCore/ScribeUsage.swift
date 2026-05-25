import Foundation
import ScribeLLM

public struct ScribeUsage: Sendable, Hashable {

  public var promptTokens: Int?

  public var completionTokens: Int?

  public var totalTokens: Int?

  public var reasoningTokens: Int?

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

  package init(_ usage: Components.Schemas.CompletionUsage) {
    self.promptTokens = usage.promptTokens
    self.completionTokens = usage.completionTokens
    self.totalTokens = usage.totalTokens
    self.reasoningTokens = usage.completionTokensDetails?.reasoningTokens
    self.cachedPromptTokens = usage.promptTokensDetails?.cachedTokens
  }
}
