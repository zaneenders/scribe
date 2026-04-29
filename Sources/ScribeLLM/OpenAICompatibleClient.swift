import Foundation
import OpenAPIAsyncHTTPClient
import OpenAPIRuntime

/// Builds an OpenAI-compatible HTTP client for chat completions.
public enum OpenAICompatibleClient {
  public static func make(serverURL: URL, bearerToken: String?) -> Client {
    Client(
      serverURL: serverURL,
      transport: AsyncHTTPClientTransport(),
      middlewares: [BearerTokenMiddleware(token: bearerToken)]
    )
  }
}
