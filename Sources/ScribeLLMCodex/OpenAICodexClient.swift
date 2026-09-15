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
}
