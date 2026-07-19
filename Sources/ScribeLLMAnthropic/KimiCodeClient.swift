import Foundation
import OpenAPIAsyncHTTPClient
import OpenAPIRuntime

public enum KimiCodeClient {
  /// Kimi Code Anthropic Messages API (`https://api.kimi.com/coding/v1/messages`).
  public static func make(serverURL: URL, token: String?) -> Client {
    Client(
      serverURL: serverURL,
      transport: AsyncHTTPClientTransport(),
      middlewares: [
        KimiCodeAuthMiddleware(token: token),
        KimiCodeUserAgentMiddleware(),
      ]
    )
  }
}
