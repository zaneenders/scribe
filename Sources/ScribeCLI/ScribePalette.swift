import SlateCore

/// Shared RGB tokens for Slate grid cells and plain-line output (``CSI`` + ``TerminalRGB``).
///
/// Vibrant spring / Easter palette: coral pinks, lavender purples, mint greens,
/// sky blues, and sunny yellows on a deep violet-black background.
enum ScribePalette {
  // MARK: - Primary accents

  /// Coral pink — "you:" prefix, queued tray
  static let orange = TerminalRGB(r: 255, g: 130, b: 150)
  /// Bright wisteria lavender — "scribe:" prefix
  static let purple = TerminalRGB(r: 185, g: 140, b: 255)
  /// Bright sky blue — answer stream text
  static let cyan = TerminalRGB(r: 70, g: 210, b: 245)
  /// Sunny daffodil — spinner, highlights
  static let yellowBright = TerminalRGB(r: 255, g: 245, b: 110)
  /// Warm buttercup — tool round headers
  static let yellow = TerminalRGB(r: 255, g: 220, b: 55)
  /// Rose pink — errors
  static let red = TerminalRGB(r: 255, g: 90, b: 130)

  // MARK: - Grays (warm undertone)

  static let grayDark = TerminalRGB(r: 105, g: 95, b: 115)
  static let grayLight = TerminalRGB(r: 215, g: 205, b: 225)
  static let gray = TerminalRGB(r: 145, g: 135, b: 155)

  static let white = TerminalRGB.white
  /// Deep violet-black — main transcript background
  static let black = TerminalRGB(r: 22, g: 18, b: 32)

  /// Bottom input strip (slightly lifted lavender-gray)
  static let inputAreaBg = TerminalRGB(r: 44, g: 40, b: 54)

  // MARK: - Usage HUD

  /// Metric labels (not numeric values)
  static let usageLabel = TerminalRGB(r: 170, g: 160, b: 185)
  /// Prompt / input tokens
  static let usagePrompt = TerminalRGB(r: 110, g: 200, b: 255)
  /// Completion / output tokens
  static let usageCompletion = TerminalRGB(r: 110, g: 240, b: 195)
  /// Reasoning / chain-of-thought tokens
  static let usageReasoning = TerminalRGB(r: 255, g: 210, b: 140)
  /// Prompt cache hits
  static let usageCache = TerminalRGB(r: 150, g: 225, b: 130)
  /// Streaming throughput
  static let usageRate = TerminalRGB(r: 255, g: 145, b: 205)
  /// Sum for current user message (tool rounds included)
  static let usageTurnSum = TerminalRGB(r: 255, g: 235, b: 150)
  /// Sum since session start
  static let usageSessionSum = TerminalRGB(r: 220, g: 185, b: 255)

  static let usageMuted = TerminalRGB(r: 128, g: 128, b: 128)

  // MARK: - Markdown styling (Vibrant Spring / Easter)

  static let markdownHeading = TerminalRGB(r: 110, g: 255, b: 190)
  static let markdownHeadingPrefix = TerminalRGB(r: 130, g: 195, b: 150)
  static let markdownBold = TerminalRGB(r: 255, g: 215, b: 110)
  static let markdownItalic = TerminalRGB(r: 255, g: 165, b: 215)
  static let markdownCode = TerminalRGB(r: 255, g: 248, b: 140)
  static let markdownCodeBlock = TerminalRGB(r: 255, g: 230, b: 90)
  static let markdownBlockquote = TerminalRGB(r: 165, g: 230, b: 170)
  static let markdownListMarker = TerminalRGB(r: 255, g: 145, b: 95)
  static let markdownLink = TerminalRGB(r: 100, g: 210, b: 255)
  static let markdownHR = TerminalRGB(r: 140, g: 200, b: 160)
}
