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

  /// Usage banner / HUD panel fills.
  static let usageBg = TerminalRGB(r: 28, g: 28, b: 28)
  static let usageRail = TerminalRGB(r: 48, g: 48, b: 48)
  static let usageMuted = TerminalRGB(r: 128, g: 128, b: 128)
  static let usageInOut = TerminalRGB(r: 135, g: 175, b: 255)
  static let usageSum = TerminalRGB(r: 215, g: 215, b: 135)
}
