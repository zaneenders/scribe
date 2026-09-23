import Foundation
import OpenAPIAsyncHTTPClient
import OpenAPIRuntime

public enum OpenAICodexClient {
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
