import Foundation
import OpenAPIAsyncHTTPClient
import OpenAPIRuntime

public enum AnthropicClient {
  /// Create a client for an Anthropic Messages-compatible API (Anthropic, Kimi Coding, etc).
  ///
  /// - Parameters:
  ///   - serverURL: The API base URL (e.g. `https://api.anthropic.com` or `https://api.kimi.com/coding`).
  ///   - apiKey: The `x-api-key` header value. Anthropic-compatible APIs use this instead of Bearer.
  ///   - anthropicVersion: The `anthropic-version` header (defaults to `"2023-06-01"`).
  public static func make(
    serverURL: URL,
    apiKey: String?,
    anthropicVersion: String? = nil
  ) -> Client {
    Client(
      serverURL: serverURL,
      transport: AsyncHTTPClientTransport(),
      middlewares: [
        AnthropicAuthMiddleware(
          apiKey: apiKey,
          anthropicVersion: anthropicVersion ?? "2023-06-01"
        )
      ]
    )
  }
}
