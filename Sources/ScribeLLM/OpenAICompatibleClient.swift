import Foundation
import OpenAPIAsyncHTTPClient
import OpenAPIRuntime

public enum OpenAICompatibleClient {
  /// Flex processing can take longer to respond; allow up to 15 minutes instead of one.
  public static func make(serverURL: URL, apiKey: String?, serviceTier: String? = nil) -> Client {
    Client(
      serverURL: serverURL,
      transport: AsyncHTTPClientTransport(
        configuration: .init(timeout: serviceTier == "flex" ? .minutes(15) : .minutes(1))),
      middlewares: [BearerTokenMiddleware(token: apiKey), UserAgentMiddleware()]
    )
  }
}
