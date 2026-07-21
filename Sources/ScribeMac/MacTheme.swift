import Chroma

/// The macOS app's palette and metrics, mirroring the CLI's dark theme
/// where Chroma's immediate-mode blocks allow.
struct MacTheme: Sendable {
  var margin: Float = 14
  var spacing: Float = 8
  var panelPadding: Float = 12
  var headerHeight: Float = 52
  var statusHeight: Float = 38
  var itemHeight: Float = 42
  var textScale: Float = 2.5
  var smallScale: Float = 2

  var background = Color(r: 0.08, g: 0.09, b: 0.13, a: 1)
  var panelBackground = Color(r: 0.10, g: 0.11, b: 0.16, a: 1)
  var headerBackground = Color(r: 0.12, g: 0.14, b: 0.22, a: 1)
  var statusBackground = Color(r: 0.09, g: 0.10, b: 0.15, a: 1)
  var composerBackground = Color(r: 0.11, g: 0.12, b: 0.18, a: 1)
  var border = Color(r: 0.22, g: 0.22, b: 0.32, a: 1)
  var buttonIdle = Color(r: 0.18, g: 0.20, b: 0.30, a: 1)
  var buttonHover = Color(r: 0.24, g: 0.28, b: 0.42, a: 1)
  var buttonPressed = Color(r: 0.30, g: 0.38, b: 0.55, a: 1)

  var accent = Color(r: 0.3, g: 0.6, b: 1.0, a: 1)
  var green = Color(r: 0.3, g: 0.8, b: 0.4, a: 1)
  var red = Color(r: 0.9, g: 0.3, b: 0.3, a: 1)
  var yellow = Color(r: 1, g: 0.85, b: 0.25, a: 1)
  var orange = Color(r: 1, g: 0.55, b: 0.15, a: 1)
  var purple = Color(r: 0.7, g: 0.3, b: 0.9, a: 1)

  var textPrimary = Color(r: 0.92, g: 0.93, b: 0.97, a: 1)
  var textSecondary = Color(r: 0.5, g: 0.5, b: 0.6, a: 1)
  var userBubbleBackground = Color(r: 0.16, g: 0.22, b: 0.34, a: 1)
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
}
