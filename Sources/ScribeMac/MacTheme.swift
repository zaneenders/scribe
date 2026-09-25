import Chroma

public struct ScribeStyle: Sendable {
  public init() {}

  public init(chromaTheme: ChromaTheme) {
    background = chromaTheme.background
    panelBackground = chromaTheme.surface
    headerBackground = chromaTheme.elevatedSurface
    statusBackground = chromaTheme.elevatedSurface
    composerBackground = chromaTheme.background
    border = chromaTheme.border
    buttonIdle = chromaTheme.button.idleBackground
    buttonHover = chromaTheme.button.hoveredBackground
    buttonPressed = chromaTheme.button.pressedBackground
    sidebarBackground = chromaTheme.elevatedSurface
    sidebarSelection = chromaTheme.button.pressedBackground
    sidebarHover = chromaTheme.button.hoveredBackground
    accent = chromaTheme.accent
    green = chromaTheme.positive
    red = chromaTheme.negative
    yellow = chromaTheme.warning
    orange = chromaTheme.warning
    purple = chromaTheme.accent
    textPrimary = chromaTheme.foreground
    textSecondary = chromaTheme.secondaryForeground
    userBubbleBackground = chromaTheme.textField.idleBackground
    reasoningText = chromaTheme.accent
    codeBackground = chromaTheme.background
    codeText = chromaTheme.positive
    inlineCodeText = chromaTheme.warning
    toolHeaderText = chromaTheme.accent
    toolOutputText = chromaTheme.secondaryForeground
    errorText = chromaTheme.negative
    warningText = chromaTheme.warning
  }

  public var cornerRadius: Float = 0
  public var sidebarPadding: Float = 0
  public var chromeBorder: Color? = nil
  public var sessionGroupStyle: ScribeSessionGroupStyle? = nil
  public var sessionRowStyle: ScribeSessionRowStyle? = nil
  public var submitButtonStyle: ButtonStyle? = nil
  public var renameColor: Color? = nil
  public var refreshColor: Color? = nil
  public var closeColor: Color? = nil
  public var transcriptBackground: Color? = nil
  public var reasoningBackground: Color? = nil
  public var userLabelColor: Color? = nil
  public var sidebarHeading: Color? = nil
  public var blue = Color(r: 0.58, g: 0.765, b: 0.89, a: 1)
  public var peach = Color(r: 0.91, g: 0.694, b: 0.569, a: 1)

  public var margin: Float = 16
  public var spacing: Float = 10
  public var panelPadding: Float = 14
  public var headerHeight: Float = 40
  public var statusHeight: Float = 44
  public var itemHeight: Float = 48
  public var sidebarWidth: Float = 320

  public var titleScale: Float = 0.7
  public var textScale: Float = 0.85
  public var smallScale: Float = 0.75

  public var background = Color(r: 0.055, g: 0.063, b: 0.085, a: 1)
  public var panelBackground = Color(r: 0.070, g: 0.080, b: 0.105, a: 1)
  public var headerBackground = Color(r: 0.085, g: 0.098, b: 0.135, a: 1)
  public var statusBackground = Color(r: 0.062, g: 0.071, b: 0.095, a: 1)
  public var composerBackground = Color(r: 0.075, g: 0.085, b: 0.115, a: 1)
  public var border = Color(r: 0.16, g: 0.18, b: 0.24, a: 1)
  public var buttonIdle = Color(r: 0.12, g: 0.14, b: 0.19, a: 1)
  public var buttonHover = Color(r: 0.18, g: 0.22, b: 0.31, a: 1)
  public var buttonPressed = Color(r: 0.24, g: 0.34, b: 0.48, a: 1)
  public var sidebarBackground = Color(r: 0.06, g: 0.068, b: 0.092, a: 1)
  public var sidebarSelection = Color(r: 0.11, g: 0.16, b: 0.23, a: 1)
  public var sidebarHover = Color(r: 0.09, g: 0.105, b: 0.145, a: 1)

  public var accent = Color(r: 0.3, g: 0.6, b: 1.0, a: 1)
  public var green = Color(r: 0.3, g: 0.8, b: 0.4, a: 1)
  public var red = Color(r: 0.9, g: 0.3, b: 0.3, a: 1)
  public var yellow = Color(r: 1, g: 0.85, b: 0.25, a: 1)
  public var orange = Color(r: 1, g: 0.55, b: 0.15, a: 1)
  public var purple = Color(r: 0.7, g: 0.3, b: 0.9, a: 1)

  public var textPrimary = Color(r: 0.90, g: 0.91, b: 0.94, a: 1)
  public var textSecondary = Color(r: 0.63, g: 0.66, b: 0.73, a: 1)
  public var userBubbleBackground = Color(r: 0.105, g: 0.15, b: 0.22, a: 1)
  public var reasoningText = Color(r: 0.55, g: 0.45, b: 0.75, a: 1)
  public var codeBackground = Color(r: 0.06, g: 0.07, b: 0.10, a: 1)
  public var codeText = Color(r: 0.75, g: 0.85, b: 0.65, a: 1)
  public var inlineCodeText = Color(r: 0.85, g: 0.70, b: 0.45, a: 1)
  public var toolHeaderText = Color(r: 0.45, g: 0.75, b: 0.85, a: 1)
  public var toolOutputText = Color(r: 0.55, g: 0.58, b: 0.68, a: 1)
  public var errorText = Color(r: 0.95, g: 0.35, b: 0.35, a: 1)
  public var warningText = Color(r: 1, g: 0.85, b: 0.25, a: 1)

  func buttonColor(for phase: InteractionPhase) -> Color {
    switch phase {
    case .idle: buttonIdle
    case .hovered: buttonHover
    case .pressed: accent
    }
  }

  func buttonStyle(pressedColor: Color? = nil, tint: Color? = nil) -> ButtonStyle {
    ButtonStyle(
      idleBackground: buttonIdle, hoveredBackground: buttonHover,
      pressedBackground: pressedColor ?? buttonPressed, foreground: tint ?? textPrimary,
      border: border, cornerRadius: cornerRadius)
  }
}

typealias MacTheme = ScribeStyle
