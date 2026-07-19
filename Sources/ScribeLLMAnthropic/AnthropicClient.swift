import Foundation
import OpenAPIAsyncHTTPClient
import OpenAPIRuntime

public enum AnthropicClient {
  /// Create a client for the Anthropic Messages API.
  ///
  /// - Parameters:
  ///   - serverURL: The API base URL (e.g. `https://api.anthropic.com`).
  ///   - apiKey: The `x-api-key` header value.
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
