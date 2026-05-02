import SlateCore

/// Shared RGB tokens for Slate grid cells and plain-line output (``CSI`` + ``TerminalRGB``).
enum ScribePalette {
  static let orange = TerminalRGB(r: 247, g: 154, b: 73)
  static let purple = TerminalRGB(r: 161, g: 117, b: 239)
  /// Classic TTY cyan (answer stream).
  static let cyan = TerminalRGB(r: 0, g: 184, b: 184)
  /// Thinking / reasoning stream (bold + this foreground in plain-line output).
  static let thinking = TerminalRGB(r: 255, g: 236, b: 90)
  static let yellow = TerminalRGB(r: 255, g: 214, b: 0)
  static let red = TerminalRGB(r: 224, g: 49, b: 49)
  static let toolName = TerminalRGB(r: 0, g: 184, b: 184)

  static let grayDark = TerminalRGB(r: 88, g: 88, b: 88)
  static let grayLight = TerminalRGB(r: 208, g: 208, b: 208)
  /// Muted / secondary text when not using ``CSI/sgrFaint``.
  static let grayDim = TerminalRGB(r: 120, g: 120, b: 120)

  static let white = TerminalRGB.white
  static let black = TerminalRGB.black

  /// Bottom input strip (distinct from main transcript black).
  static let inputAreaBg = TerminalRGB(r: 32, g: 32, b: 40)

  /// Usage HUD: metric labels (not numeric values)
  static let usageLabel = TerminalRGB(r: 145, g: 145, b: 155)
  /// Tokens billed as prompt / input side
  static let usagePrompt = TerminalRGB(r: 120, g: 195, b: 255)
  /// Completion / output tokens
  static let usageCompletion = TerminalRGB(r: 115, g: 230, b: 195)
  /// Reasoning / chain-of-thought slice of usage
  static let usageReasoning = TerminalRGB(r: 255, g: 210, b: 115)
  /// Prompt cache hits (served from cache)
  static let usageCache = TerminalRGB(r: 150, g: 215, b: 130)
  /// Streaming throughput
  static let usageRate = TerminalRGB(r: 255, g: 145, b: 195)
  /// Sum for current user message (tool rounds included)
  static let usageTurnSum = TerminalRGB(r: 255, g: 225, b: 135)
  /// Sum since session start
  static let usageSessionSum = TerminalRGB(r: 210, g: 175, b: 255)

  static let usageMuted = TerminalRGB(r: 128, g: 128, b: 128)
}
