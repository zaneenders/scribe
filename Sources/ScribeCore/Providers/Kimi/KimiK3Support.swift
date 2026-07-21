import Foundation
import ScribeLLM

enum ChatCompletionRequestProfile: Sendable {
  case standard
  case moonshotK3
  case kimiCode
}

enum KimiTransport: Sendable {
  case moonshotOpenAI
  case kimiCodeOpenAI
}

public enum KimiK3Support {
  public static let defaultMaxCompletionTokens = 131_072
  public static let maxCompletionTokensLimit = 1_048_576

  public static func effectiveMaxCompletionTokens(_ configured: Int?) -> Int {
    configured ?? defaultMaxCompletionTokens
  }
  public static let moonshotBaseURL = "https://api.moonshot.ai"
  public static let kimiCodeBaseURL = "https://api.kimi.com/coding"

  public static func isKimiCodeAPIKey(_ apiKey: String) -> Bool {
    apiKey.hasPrefix("sk-kimi-")
  }

  public static func isKimiCodeBaseURL(_ serverURL: String) -> Bool {
    let trimmed = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let components = URLComponents(string: trimmed),
      let host = components.host?.lowercased()
    else { return false }
    return host == "api.kimi.com" && components.path.hasPrefix("/coding")
  }

  static func resolveTransport(apiKey: String?, serverURL: String) throws -> KimiTransport {
    let base = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
    if isKimiCodeBaseURL(base) {
      guard let apiKey, !apiKey.isEmpty else {
        throw ScribeError.configuration(
          key: "api.apiKey",
          reason: "api.baseUrl \"\(kimiCodeBaseURL)\" requires a Kimi Code API key."
        )
      }
      guard isKimiCodeAPIKey(apiKey) else {
        throw ScribeError.configuration(
          key: "api.apiKey",
          reason:
            "api.baseUrl \"\(kimiCodeBaseURL)\" requires a Kimi Code API key (sk-kimi-…); Moonshot platform keys use https://api.moonshot.ai."
        )
      }
      return .kimiCodeOpenAI
    }
    if let apiKey, !apiKey.isEmpty, isKimiCodeAPIKey(apiKey) {
      if base.contains("moonshot.ai") || base.contains("moonshot.cn") {
        throw ScribeError.configuration(
          key: "api.baseUrl",
          reason:
            "Kimi Code API keys only work with api.baseUrl \"\(kimiCodeBaseURL)\", not Moonshot platform URLs. Create a key at kimi.com/code or change api.baseUrl."
        )
      }
      return .kimiCodeOpenAI
    }
    return .moonshotOpenAI
  }

  public static func validateEndpoint(apiKey: String?, serverURL: String) throws {
    _ = try resolveTransport(apiKey: apiKey, serverURL: serverURL)
  }

  public static func validateMaxCompletionTokens(_ value: Int?) throws {
    guard let value else { return }
    guard (1...maxCompletionTokensLimit).contains(value) else {
      throw ScribeError.configuration(
        key: "agent.maxTokens",
        reason:
          "Kimi max_completion_tokens must be between 1 and \(maxCompletionTokensLimit); got \(value)."
      )
    }
  }

  public static func validateMessages(_ messages: [Components.Schemas.ChatMessage]) throws {
    for message in messages {
      guard let content = message.content else { continue }
      guard case .case2(let parts) = content else { continue }
      for part in parts {
        guard case .imageUrl(let payload) = part else { continue }
        try validateImageURL(payload.imageUrl.url)
      }
    }
  }

  public static func validateImageURL(_ url: String) throws {
    if url.hasPrefix("data:") { return }
    if url.hasPrefix("ms://") { return }
    throw ScribeError.invalidInput(
      message:
        "Kimi vision input must use base64 data URIs or ms:// file references; public URLs are not supported."
    )
  }
}
