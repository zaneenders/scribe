import SlateCore

/// Shared RGB tokens for Slate grid cells and plain-line output (``CSI`` + ``TerminalRGB``).
enum ScribePalette {
  static let orange = TerminalRGB(r: 247, g: 154, b: 73)
  static let purple = TerminalRGB(r: 161, g: 117, b: 239)
  /// Classic TTY cyan (answer stream).
  static let cyan = TerminalRGB(r: 0, g: 184, b: 184)
  static let yellowBright = TerminalRGB(r: 255, g: 236, b: 90)
  static let yellow = TerminalRGB(r: 255, g: 214, b: 0)
  static let red = TerminalRGB(r: 224, g: 49, b: 49)
  static let grayDark = TerminalRGB(r: 88, g: 88, b: 88)
  static let grayLight = TerminalRGB(r: 208, g: 208, b: 208)
  static let gray = TerminalRGB(r: 120, g: 120, b: 120)

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

  // MARK: - Markdown styling (Vibrant Spring)

  static let markdownHeading = TerminalRGB(r: 120, g: 255, b: 180)
  static let markdownHeadingPrefix = TerminalRGB(r: 100, g: 160, b: 120)
  static let markdownBold = TerminalRGB(r: 255, g: 200, b: 100)
  static let markdownItalic = TerminalRGB(r: 255, g: 150, b: 200)
  static let markdownCode = TerminalRGB(r: 255, g: 240, b: 120)
  static let markdownCodeBlock = TerminalRGB(r: 255, g: 220, b: 80)
  static let markdownBlockquote = TerminalRGB(r: 150, g: 220, b: 150)
  static let markdownListMarker = TerminalRGB(r: 255, g: 130, b: 80)
  static let markdownLink = TerminalRGB(r: 100, g: 200, b: 255)
  static let markdownHR = TerminalRGB(r: 120, g: 180, b: 140)
}
