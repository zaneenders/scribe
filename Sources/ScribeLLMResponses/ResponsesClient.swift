import AsyncHTTPClient
import Foundation
import OpenAPIAsyncHTTPClient
import OpenAPIRuntime
import ScribeCodexAuth

public enum ResponsesClient {
  private static let codexHTTP: HTTPClient = {
    var configuration = HTTPClient.Configuration()
    configuration.redirectConfiguration = .disallow
    return HTTPClient(eventLoopGroupProvider: .singleton, configuration: configuration)
  }()
  /// Reads the current login for every request and refreshes once if the server rejects it.
  public static func makeAuthenticated(
    serverURL: URL, baseDirectory: URL? = nil, credentials: (any CodexAccessCredentialProvider)? = nil
  ) -> Client {
    let provider = credentials ?? CodexDefaultAccessProvider(baseDirectory: baseDirectory)
    return Client(
      serverURL: serverURL,
      transport: AsyncHTTPClientTransport(configuration: .init(client: codexHTTP)),
      middlewares: [
        CodexAuthMiddleware { rejectedToken in
          try await provider.credential(rejectingAccessToken: rejectedToken)
        }
      ])
  }

  public static func make(
    serverURL: URL,
    accessToken: String?,
    accountID: String?
  ) -> Client {
    Client(
      serverURL: serverURL,
      transport: AsyncHTTPClientTransport(configuration: .init(client: codexHTTP)),
      middlewares: [
        CodexAuthMiddleware(token: accessToken, accountID: accountID)
      ]
    )
  }

  /// Use the Responses API with a bearer API key instead of ChatGPT OAuth.
  /// Flex processing can take longer to respond; allow up to 15 minutes instead of one.
  public static func makeResponses(serverURL: URL, apiKey: String?, serviceTier: String? = nil) -> Client {
    Client(
      serverURL: serverURL,
      transport: AsyncHTTPClientTransport(
        configuration: .init(timeout: serviceTier == "flex" ? .minutes(15) : .minutes(1))),
      middlewares: [ResponsesAPIMiddleware(apiKey: apiKey)]
    )
  }
}
