import Foundation
import OpenAPIAsyncHTTPClient
import OpenAPIRuntime

public enum OpenAICompatibleClient {
  public static func make(serverURL: URL, apiKey: String?) -> Client {
    Client(
      serverURL: serverURL,
      transport: AsyncHTTPClientTransport(),
      middlewares: [BearerTokenMiddleware(token: apiKey)]
    )
  }

  /// OpenAI-compatible client for Kimi Code (`api.kimi.com/coding`).
  public static func makeForKimiCode(
    serverURL: URL,
    apiKey: String?,
    headers: [String: String]
  ) -> Client {
    Client(
      serverURL: serverURL,
      transport: AsyncHTTPClientTransport(),
      middlewares: [
        BearerTokenMiddleware(token: apiKey),
        KimiCodeRequestMiddleware(headers: headers),
      ]
    )
  }
}
