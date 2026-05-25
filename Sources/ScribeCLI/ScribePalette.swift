import SlateCore

/// Shared RGB tokens for Slate grid cells and plain-line output (``CSI`` + ``TerminalRGB``).
///
/// Vibrant Easter-pastel palette: coral pinks, wisteria lavenders, mint greens,
/// sky blues, and soft peach on a deep violet-black background.
enum ScribePalette {

  /// Coral pink — "you:" prefix, queued tray
  static let orange = TerminalRGB(r: 255, g: 130, b: 150)
  /// Bright wisteria lavender — "scribe:" prefix
  static let purple = TerminalRGB(r: 185, g: 140, b: 255)
  /// Light sky-blue white — answer stream text
  static let cyan = TerminalRGB(r: 185, g: 222, b: 252)
  /// Warm peach — spinner, highlights
  static let yellowBright = TerminalRGB(r: 255, g: 200, b: 160)
  /// Soft lemon — tool round headers, ctx% warn
  static let yellow = TerminalRGB(r: 240, g: 228, b: 130)
  /// Rose pink — errors
  static let red = TerminalRGB(r: 255, g: 90, b: 130)


  static let grayDark = TerminalRGB(r: 105, g: 95, b: 115)
  static let grayLight = TerminalRGB(r: 215, g: 205, b: 225)
  static let gray = TerminalRGB(r: 145, g: 135, b: 155)

  static let white = TerminalRGB.white
  /// Deep violet-black — main transcript background
  static let black = TerminalRGB(r: 22, g: 18, b: 32)

  /// Bottom input strip (slightly lifted lavender-gray)
  static let inputAreaBg = TerminalRGB(r: 44, g: 40, b: 54)


  /// Metric labels (not numeric values)
  static let usageLabel = TerminalRGB(r: 170, g: 160, b: 185)
  /// Prompt / input tokens
  static let usagePrompt = TerminalRGB(r: 110, g: 200, b: 255)
  /// Completion / output tokens
  static let usageCompletion = TerminalRGB(r: 110, g: 240, b: 195)
  /// Reasoning / chain-of-thought tokens
  static let usageReasoning = TerminalRGB(r: 245, g: 200, b: 155)
  /// Prompt cache hits
  static let usageCache = TerminalRGB(r: 150, g: 225, b: 130)
  /// Streaming throughput
  static let usageRate = TerminalRGB(r: 255, g: 145, b: 205)
  /// Sum for current user message (tool rounds included)
  static let usageTurnSum = TerminalRGB(r: 230, g: 210, b: 170)
  /// Sum since session start
  static let usageSessionSum = TerminalRGB(r: 220, g: 185, b: 255)

  static let usageMuted = TerminalRGB(r: 128, g: 128, b: 128)


  static let markdownHeading = TerminalRGB(r: 80, g: 255, b: 185)
  static let markdownHeadingPrefix = TerminalRGB(r: 120, g: 210, b: 155)
  static let markdownBold = TerminalRGB(r: 255, g: 175, b: 200)
  static let markdownItalic = TerminalRGB(r: 255, g: 155, b: 215)
  static let markdownCode = TerminalRGB(r: 225, g: 220, b: 235)
  static let markdownCodeBlock = TerminalRGB(r: 195, g: 190, b: 210)
  static let markdownBlockquote = TerminalRGB(r: 155, g: 235, b: 175)
  static let markdownListMarker = TerminalRGB(r: 255, g: 140, b: 85)
  static let markdownLink = TerminalRGB(r: 75, g: 215, b: 255)
  static let markdownHR = TerminalRGB(r: 130, g: 210, b: 165)


  static let grayHeading = TerminalRGB(r: 235, g: 232, b: 240)
  static let grayHeadingPrefix = TerminalRGB(r: 150, g: 147, b: 165)
  static let grayBold = TerminalRGB(r: 220, g: 218, b: 228)
  static let grayItalic = TerminalRGB(r: 175, g: 170, b: 188)
  static let grayCode = TerminalRGB(r: 190, g: 187, b: 202)
  static let grayCodeBlock = TerminalRGB(r: 165, g: 160, b: 180)
  static let grayBlockquote = TerminalRGB(r: 150, g: 147, b: 165)
  static let grayListMarker = TerminalRGB(r: 130, g: 127, b: 148)
  static let grayLink = TerminalRGB(r: 160, g: 155, b: 175)
  static let grayHR = TerminalRGB(r: 120, g: 117, b: 138)
}
