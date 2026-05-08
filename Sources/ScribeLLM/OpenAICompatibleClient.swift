import Foundation
import OpenAPIAsyncHTTPClient
import OpenAPIRuntime

/// Builds an OpenAI-compatible HTTP client for chat completions.
public enum OpenAICompatibleClient {
  public static func make(serverURL: URL, apiKey: String?) -> Client {
    Client(
      serverURL: serverURL,
      transport: AsyncHTTPClientTransport(),
      middlewares: [BearerTokenMiddleware(token: apiKey)]
    )
  }
}
