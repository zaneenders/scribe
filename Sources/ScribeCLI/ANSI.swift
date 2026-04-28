enum ANSI {
  static let reset = "\u{001B}[0m"
  static let bold = "\u{001B}[1m"
  static let dim = "\u{001B}[2m"
  static let red = "\u{001B}[31m"
  static let green = "\u{001B}[32m"
  static let yellow = "\u{001B}[33m"
  static let orange = "\u{001B}[38;2;247;154;73m"
  static let blue = "\u{001B}[34m"
  static let magenta = "\u{001B}[35m"
  static let purple = "\u{001B}[38;2;161;117;239m"
  static let cyan = "\u{001B}[36m"

  /// Darker gray (e.g. banner labels).
  static let grayDark = "\u{001B}[38;5;240m"
  /// Lighter gray (e.g. banner values).
  static let grayLight = "\u{001B}[38;5;252m"

  /// Thinking stream: bold + vivid yellow (truecolor for terminals that support it).
  static let thinking = "\(bold)\u{001B}[38;2;255;236;90m"

  // MARK: - Usage panel (256-color; use `reset` only after the full panel)

  /// Dark gray fill for token-usage panel rows.
  static let usagePanelBg = "\u{001B}[48;5;234m"
  /// Slightly lighter gray strip (top/bottom “rails”).
  static let usagePanelRailBg = "\u{001B}[48;5;236m"
  static let usagePanelMuted = "\u{001B}[38;5;244m"
  static let usagePanelIn = "\u{001B}[38;5;117m"
  static let usagePanelOut = "\u{001B}[38;5;117m"
  static let usagePanelSum = "\u{001B}[1m\u{001B}[38;5;187m"
}
