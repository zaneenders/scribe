import AsyncHTTPClient
import Foundation

public struct CodexUsage: Decodable, Sendable {
  public struct Window: Decodable, Sendable {
    public let usedPercent: Double
    public let resetAt: Int64
    public let limitWindowSeconds: Int

    public var remainingPercent: Double { min(100, max(0, 100 - usedPercent)) }

    enum CodingKeys: String, CodingKey {
      case usedPercent = "used_percent"
      case resetAt = "reset_at"
      case limitWindowSeconds = "limit_window_seconds"
    }
  }

  public struct RateLimit: Decodable, Sendable {
    public let primaryWindow: Window?
    public let secondaryWindow: Window?

    enum CodingKeys: String, CodingKey {
      case primaryWindow = "primary_window"
      case secondaryWindow = "secondary_window"
    }
  }

  public let rateLimit: RateLimit?

  enum CodingKeys: String, CodingKey {
    case rateLimit = "rate_limit"
  }

  private static let client: HTTPClient = {
    var configuration = HTTPClient.Configuration()
    configuration.redirectConfiguration = .disallow
    return HTTPClient(eventLoopGroupProvider: .singleton, configuration: configuration)
  }()

  public static func fetch() async throws -> CodexUsage {
    var credential = try await CodexOAuth.getValidCredentials()
    for attempt in 0..<2 {
      var request = HTTPClientRequest(url: "https://chatgpt.com/backend-api/wham/usage")
      request.headers.add(name: "Authorization", value: "Bearer \(credential.access)")
      request.headers.add(name: "ChatGPT-Account-Id", value: credential.accountId)
      let response = try await client.execute(request, timeout: .seconds(20))
      let body = try await response.body.collect(upTo: 1_048_576)
      if response.status == .unauthorized {
        guard attempt == 0 else { throw CodexOAuthError.loginRequired }
        credential = try await CodexOAuth.getValidCredentials(rejectingAccessToken: credential.access)
        continue
      }
      guard response.status == .ok else { throw UsageError.unavailable }
      return try JSONDecoder().decode(CodexUsage.self, from: Data(body.readableBytesView))
    }
    throw UsageError.unavailable
  }

  private enum UsageError: Error { case unavailable }
}
