import Foundation

public enum ScribeError: Error, Sendable, LocalizedError, Equatable {
  case configuration(key: String?, reason: String)
  case apiHTTPError(statusCode: Int, detail: String, hint: String?)
  /// An error reported inside an otherwise successful provider event stream.
  /// `code` and `type` are retained so retry policy can distinguish transient
  /// server failures from invalid requests and other permanent failures.
  case providerStreamError(detail: String, code: String?, type: String?)
  case toolUnknown(name: String)
  case sessionCorrupted(reason: String)
  case resumeNotFound(specifier: String)
  case resumeAmbiguous(specifier: String)
  case invalidInput(message: String)
  case generic(String)

  public var errorDescription: String? {
    switch self {
    case .configuration(_, let reason):
      return reason
    case .apiHTTPError(let statusCode, let detail, let hint):
      var msg = "chat/completions returned HTTP \(statusCode)"
      if !detail.isEmpty {
        msg += " — \(detail)"
      }
      if let hint, !hint.isEmpty {
        msg += ".\(hint)"
      }
      return msg
    case .providerStreamError(let detail, _, _):
      return detail
    case .toolUnknown(let name):
      return "Unknown tool \"\(name)\""
    case .sessionCorrupted(let reason):
      return reason
    case .resumeNotFound(let specifier):
      return "No session matches \"\(specifier)\". Try `scribe chat --sessions`."
    case .resumeAmbiguous(let specifier):
      return "Ambiguous session prefix \"\(specifier)\"; use a longer id or a full path."
    case .invalidInput(let message):
      return message
    case .generic(let message):
      return message
    }
  }
}
