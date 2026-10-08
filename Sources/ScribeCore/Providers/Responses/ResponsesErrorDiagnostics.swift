import AsyncHTTPClient
import Foundation
import Logging
import NIOCore
import OpenAPIRuntime

/// Diagnostic dimensions only. Error descriptions, ClientError request/response fields,
/// NSError userInfo, and arbitrary provider strings may contain credentials or content.
func responsesErrorMetadata(_ error: any Error) -> Logger.Metadata {
  var underlying = error
  while let clientError = underlying as? ClientError {
    underlying = clientError.underlyingError
  }
  var metadata: Logger.Metadata = [
    "error_type": "\(String(reflecting: type(of: error)))",
    "underlying_error_type": "\(String(reflecting: type(of: underlying)))",
    "retryable": "\(RetryPolicy.default.isRetryable(error))",
    "task_cancelled": "\(Task.isCancelled)",
  ]
  switch underlying {
  case let httpError as HTTPClientError:
    // Unlike description, shortDescription never includes associated values.
    metadata["error_code"] = "\(httpError.shortDescription)"
  case let urlError as URLError:
    metadata["error_code"] = "\(urlError.code.rawValue)"
  case let ioError as IOError:
    metadata["error_code"] = "\(ioError.errnoCode)"
  case let channelError as ChannelError:
    switch channelError {
    case .eof: metadata["error_code"] = "eof"
    case .ioOnClosedChannel: metadata["error_code"] = "io_on_closed_channel"
    case .outputClosed: metadata["error_code"] = "output_closed"
    case .inputClosed: metadata["error_code"] = "input_closed"
    case .alreadyClosed: metadata["error_code"] = "already_closed"
    case .connectTimeout: metadata["error_code"] = "connect_timeout"
    default: metadata["error_code"] = "other_channel_error"
    }
  case is CancellationError:
    metadata["error_code"] = "cancelled"
  case let decodingError as DecodingError:
    switch decodingError {
    case .dataCorrupted: metadata["error_code"] = "data_corrupted"
    case .keyNotFound: metadata["error_code"] = "key_not_found"
    case .typeMismatch: metadata["error_code"] = "type_mismatch"
    case .valueNotFound: metadata["error_code"] = "value_not_found"
    @unknown default: metadata["error_code"] = "other_decoding_error"
    }
  default:
    break
  }
  return metadata
}
