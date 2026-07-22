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

/// Controls how the agent loop reacts to transient networking failures: a failed
/// provider round is retried up to `maxRetries` times with full-jitter exponential
/// backoff between attempts.
///
/// A round is only retried while it has produced no visible stream output; once
/// assistant content reaches the transcript, replaying the round would duplicate it.
public struct RetryPolicy: Sendable {
  /// Number of retries after the initial attempt. `0` disables retrying.
  public var maxRetries: Int
  /// Backoff ceiling for the first retry; later retries grow by `multiplier`.
  public var initialDelay: Duration
  /// Upper bound for a single backoff.
  public var maxDelay: Duration
  /// Growth factor applied per retry attempt.
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

  /// Default policy: 3 retries, 1s initial backoff doubling to at most 20s.
  public static let `default` = RetryPolicy()

  /// Full-jitter exponential backoff for a 1-based retry attempt: a random delay
  /// between zero and `min(maxDelay, initialDelay * multiplier^(attempt - 1))`.
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

// MARK: - Transient failure classification

extension RetryPolicy {
  /// True when `error` is a transient networking failure worth retrying: rate limiting
  /// (HTTP 429), request timeout (408), server errors (5xx), or a transport-level
  /// failure such as a dropped connection or timeout. Other client errors (4xx),
  /// malformed streams, and cancellations are not retried.
  func isRetryable(_ error: any Error) -> Bool {
    switch error {
    case is CancellationError, is AgentTurnInterruptedError:
      return false
    case let scribeError as ScribeError:
      guard case .apiHTTPError(let statusCode, _, _) = scribeError else { return false }
      return statusCode == 408 || statusCode == 429 || (500...599).contains(statusCode)
    case let clientError as ClientError:
      // OpenAPIRuntime wraps transport and middleware failures; classify the cause.
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
}

extension URLError.Code {
  /// Connection-level failures that may succeed on retry, mirroring the transient
  /// transport failures surfaced by the NIO stack.
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
