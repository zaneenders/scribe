import Foundation

/// ANSI escape sequences for terminal styling (no coupling to agent protocols).
public enum ANSI {
  public static let reset = "\u{001B}[0m"
  public static let bold = "\u{001B}[1m"
  public static let dim = "\u{001B}[2m"
  public static let red = "\u{001B}[31m"
  public static let green = "\u{001B}[32m"
  public static let yellow = "\u{001B}[33m"
  public static let orange = "\u{001B}[38;2;247;154;73m"
  public static let blue = "\u{001B}[34m"
  public static let magenta = "\u{001B}[35m"
  public static let purple = "\u{001B}[38;2;161;117;239m"
  public static let cyan = "\u{001B}[36m"

  /// Darker gray (e.g. banner labels).
  public static let grayDark = "\u{001B}[38;5;240m"
  /// Lighter gray (e.g. banner values).
  public static let grayLight = "\u{001B}[38;5;252m"

  /// Thinking stream: bold + vivid yellow (truecolor for terminals that support it).
  public static let thinking = "\(bold)\u{001B}[38;2;255;236;90m"

  // MARK: - Usage panel (256-color; use `reset` only after the full panel)

  public static let usagePanelBg = "\u{001B}[48;5;234m"
  public static let usagePanelRailBg = "\u{001B}[48;5;236m"
  public static let usagePanelMuted = "\u{001B}[38;5;244m"
  public static let usagePanelIn = "\u{001B}[38;5;117m"
  public static let usagePanelOut = "\u{001B}[38;5;117m"
  public static let usagePanelSum = "\u{001B}[1m\u{001B}[38;5;187m"
}
