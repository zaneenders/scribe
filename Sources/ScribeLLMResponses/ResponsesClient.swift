import Foundation
import OpenAPIAsyncHTTPClient
import OpenAPIRuntime
import ScribeCodexAuth

public enum ResponsesClient {
  /// Reads the current login for every request and refreshes once if the server rejects it.
  public static func makeAuthenticated(serverURL: URL, baseDirectory: URL? = nil) -> Client {
    Client(
      serverURL: serverURL,
      transport: AsyncHTTPClientTransport(),
      middlewares: [
        CodexAuthMiddleware { rejectedToken in
          try await CodexOAuth.getValidCredentials(
            baseDirectory: baseDirectory, rejectingAccessToken: rejectedToken)
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
      transport: AsyncHTTPClientTransport(),
      middlewares: [
        CodexAuthMiddleware(token: accessToken, accountID: accountID)
      ]
    )
  }

  /// Use the Responses API with a bearer API key instead of ChatGPT OAuth.
  public static func makeResponses(serverURL: URL, apiKey: String?) -> Client {
    Client(
      serverURL: serverURL,
      transport: AsyncHTTPClientTransport(),
      middlewares: [ResponsesAPIMiddleware(apiKey: apiKey)]
    )
  }
}
