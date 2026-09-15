import AsyncHTTPClient
import Foundation
import NIOCore
import OpenAPIRuntime

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

public struct RetryPolicy: Sendable {
  public var maxRetries: Int
  public var initialDelay: Duration
  public var maxDelay: Duration
  public var multiplier: Double

  public init(
    maxRetries: Int = 3,
    initialDelay: Duration = .seconds(1),
    maxDelay: Duration = .seconds(20),
    multiplier: Double = 2
  ) {
    self.maxRetries = max(0, maxRetries)
    self.initialDelay = initialDelay
    self.maxDelay = maxDelay
    self.multiplier = multiplier
  }

  public static let `default` = RetryPolicy()

  func delay(forRetryAttempt attempt: Int) -> Duration {
    let base = Self.seconds(initialDelay)
    let cap = Self.seconds(maxDelay)
    let exponent = Double(max(1, attempt) - 1)
    let ceiling = min(cap, base * pow(multiplier, exponent))
    let jittered = Double.random(in: 0...ceiling)
    return .nanoseconds(Int64((jittered * 1_000_000_000).rounded()))
  }

  private static func seconds(_ duration: Duration) -> Double {
    Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
  }
}

extension RetryPolicy {
  func isRetryable(_ error: any Error) -> Bool {
    switch error {
    case is CancellationError, is AgentTurnInterruptedError:
      return false
    case let scribeError as ScribeError:
      switch scribeError {
      case .apiHTTPError(let statusCode, _, _):
        return statusCode == 408 || statusCode == 429 || (500...599).contains(statusCode)
      case .providerStreamError(_, let code, let type):
        return Self.isRetryableProviderStreamError(code: code, type: type)
      default:
        return false
      }
    case let clientError as ClientError:
      return isRetryable(clientError.underlyingError)
    case let urlError as URLError:
      return urlError.code.isTransientNetworkFailure
    case let httpError as HTTPClientError:
      switch httpError {
      case .connectTimeout, .readTimeout, .writeTimeout, .deadlineExceeded,
        .remoteConnectionClosed, .getConnectionFromPoolTimeout,
        .socksHandshakeTimeout, .httpProxyHandshakeTimeout, .tlsHandshakeTimeout,
        .uncleanShutdown, .invalidProxyResponse:
        return true
      default:
        return false
      }
    case let channelError as ChannelError:
      switch channelError {
      case .eof, .ioOnClosedChannel, .outputClosed, .inputClosed, .alreadyClosed,
        .connectTimeout:
        return true
      default:
        return false
      }
    case let ioError as IOError:
      switch ioError.errnoCode {
      case ECONNRESET, ECONNABORTED, ECONNREFUSED, EPIPE, ETIMEDOUT,
        EHOSTUNREACH, EHOSTDOWN, ENETUNREACH, ENETDOWN:
        return true
      default:
        return false
      }
    default:
      return false
    }
  }

  private static func isRetryableProviderStreamError(code: String?, type: String?) -> Bool {
    let normalizedCode = code?.lowercased()
    let normalizedType = type?.lowercased()
    let retryableValues: Set<String> = [
      "server_error",
      "internal_server_error",
      "service_unavailable",
      "overloaded",
      "rate_limit_error",
      "rate_limit_exceeded",
      "timeout",
      "request_timeout",
    ]
    return normalizedCode.map(retryableValues.contains) == true
      || normalizedType.map(retryableValues.contains) == true
  }
}

extension URLError.Code {
  fileprivate var isTransientNetworkFailure: Bool {
    switch self {
    case .timedOut, .cannotFindHost, .cannotConnectToHost, .networkConnectionLost,
      .dnsLookupFailed, .notConnectedToInternet, .dataNotAllowed, .callIsActive,
      .internationalRoamingOff, .secureConnectionFailed:
      return true
    default:
      return false
    }
  }
}
