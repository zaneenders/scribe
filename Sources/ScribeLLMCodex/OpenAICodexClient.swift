import Foundation
import OpenAPIAsyncHTTPClient
import OpenAPIRuntime

public enum OpenAICodexClient {
  /// Create a client for the ChatGPT subscription (Codex) backend.
  ///
  /// - Parameters:
  ///   - serverURL: The Codex API base URL (defaults to `https://chatgpt.com/backend-api`).
  ///   - accessToken: OAuth access token from the ChatGPT login flow.
  ///   - accountID: The `chatgpt-account-id` extracted from the JWT's
  ///     `https://api.openai.com/auth` claim.
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
