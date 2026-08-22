import Chroma

/// The macOS app's palette and metrics, mirroring the CLI's dark theme
/// where Chroma's immediate-mode blocks allow.
struct MacTheme: Sendable {
  var margin: Float = 16
  var spacing: Float = 10
  var panelPadding: Float = 14
  var headerHeight: Float = 64
  var statusHeight: Float = 44
  var itemHeight: Float = 48
  var sidebarWidth: Float = 320

  // Large, high-contrast defaults are deliberate: the app should remain easy
  // to scan without leaning toward the display. Body text lands around 17 pt.
  var titleScale: Float = 0.7
  var textScale: Float = 0.85
  var smallScale: Float = 0.75
  // Keep the surrounding app comfortably large, but give full-screen terminal
  // programs such as Neovim enough rows and columns to be useful.
  var terminalScale: Float = 0.65

  var background = Color(r: 0.055, g: 0.063, b: 0.085, a: 1)
  var panelBackground = Color(r: 0.070, g: 0.080, b: 0.105, a: 1)
  var headerBackground = Color(r: 0.085, g: 0.098, b: 0.135, a: 1)
  var statusBackground = Color(r: 0.062, g: 0.071, b: 0.095, a: 1)
  var composerBackground = Color(r: 0.075, g: 0.085, b: 0.115, a: 1)
  var border = Color(r: 0.16, g: 0.18, b: 0.24, a: 1)
  var buttonIdle = Color(r: 0.12, g: 0.14, b: 0.19, a: 1)
  var buttonHover = Color(r: 0.18, g: 0.22, b: 0.31, a: 1)
  var buttonPressed = Color(r: 0.24, g: 0.34, b: 0.48, a: 1)
  var sidebarBackground = Color(r: 0.06, g: 0.068, b: 0.092, a: 1)
  var sidebarSelection = Color(r: 0.11, g: 0.16, b: 0.23, a: 1)
  var sidebarHover = Color(r: 0.09, g: 0.105, b: 0.145, a: 1)

  var accent = Color(r: 0.3, g: 0.6, b: 1.0, a: 1)
  var green = Color(r: 0.3, g: 0.8, b: 0.4, a: 1)
  var red = Color(r: 0.9, g: 0.3, b: 0.3, a: 1)
  var yellow = Color(r: 1, g: 0.85, b: 0.25, a: 1)
  var orange = Color(r: 1, g: 0.55, b: 0.15, a: 1)
  var purple = Color(r: 0.7, g: 0.3, b: 0.9, a: 1)

  // Body copy is intentionally softer than pure white. The display face and
  // colored status accents can stay crisp without making long answers glare.
  var textPrimary = Color(r: 0.90, g: 0.91, b: 0.94, a: 1)
  var textSecondary = Color(r: 0.63, g: 0.66, b: 0.73, a: 1)
  var userBubbleBackground = Color(r: 0.105, g: 0.15, b: 0.22, a: 1)
  var reasoningText = Color(r: 0.55, g: 0.45, b: 0.75, a: 1)
  var codeBackground = Color(r: 0.06, g: 0.07, b: 0.10, a: 1)
  var codeText = Color(r: 0.75, g: 0.85, b: 0.65, a: 1)
  var inlineCodeText = Color(r: 0.85, g: 0.70, b: 0.45, a: 1)
  var toolHeaderText = Color(r: 0.45, g: 0.75, b: 0.85, a: 1)
  var toolOutputText = Color(r: 0.55, g: 0.58, b: 0.68, a: 1)
  var errorText = Color(r: 0.95, g: 0.35, b: 0.35, a: 1)
  var warningText = Color(r: 1, g: 0.85, b: 0.25, a: 1)

  func buttonColor(for phase: InteractionPhase) -> Color {
    switch phase {
    case .idle: buttonIdle
    case .hovered: buttonHover
    case .pressed: accent
    }
  }

  func buttonStyle(pressedColor: Color? = nil) -> ButtonStyle {
    ButtonStyle(
      idleBackground: buttonIdle,
      hoveredBackground: buttonHover,
      pressedBackground: pressedColor ?? buttonPressed,
      foreground: textPrimary,
      border: border,
      cornerRadius: 0
    )
  }
}
