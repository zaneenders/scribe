import Foundation
import Logging

public enum ScribeLogLevel: String, Sendable, CaseIterable {
  case trace
  case debug
  case info
  case notice
  case warning
  case error

  public var priority: Int {
    switch self {
    case .trace: 0
    case .debug: 1
    case .info: 2
    case .notice: 3
    case .warning: 4
    case .error: 5
    }
  }

  public var swiftLogLevel: Logger.Level {
    Logger.Level(rawValue: rawValue) ?? .info
  }

  init?(parsingConfig raw: String) {
    let s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !s.isEmpty else { return nil }
    self.init(rawValue: s)
  }
}
