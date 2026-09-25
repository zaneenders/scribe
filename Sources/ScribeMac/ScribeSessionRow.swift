import Chroma

public struct ScribeSessionRowStyle: Sendable {
  public var foreground: Color
  public var secondaryForeground: Color
  public var selectedForeground: Color
  public var activity: Color
  public var selection: Color
  public var hover: Color
  public var border: Color
  public var fontScale: Float
  public var cornerRadius: Float

  public init(
    foreground: Color, secondaryForeground: Color, selectedForeground: Color,
    activity: Color, selection: Color, hover: Color, border: Color,
    fontScale: Float, cornerRadius: Float = 0
  ) {
    self.foreground = foreground
    self.secondaryForeground = secondaryForeground
    self.selectedForeground = selectedForeground
    self.activity = activity
    self.selection = selection
    self.hover = hover
    self.border = border
    self.fontScale = fontScale
    self.cornerRadius = cornerRadius
  }
}

public struct ScribeSessionRow: Block {
  let id: String
  let title: String
  let subtitle: String
  let isSelected: Bool
  let isRunning: Bool
  let isUnread: Bool
  let style: ScribeSessionRowStyle
  let onSelect: @MainActor () -> Void

  public init(
    id: String, title: String, subtitle: String, isSelected: Bool,
    isRunning: Bool = false, isUnread: Bool = false, style: ScribeSessionRowStyle,
    onSelect: @escaping @MainActor () -> Void
  ) {
    self.id = id
    self.title = title
    self.subtitle = subtitle
    self.isSelected = isSelected
    self.isRunning = isRunning
    self.isUnread = isUnread
    self.style = style
    self.onSelect = onSelect
  }

  @MainActor public var body: some Block {
    Interactive(action: onSelect) { phase in
      HStack(spacing: 5) {
        if isRunning { ActivitySpinner(color: style.activity) }
        MarqueeText(
          title, id: id,
          color: isRunning ? style.activity
            : isSelected ? style.selectedForeground : style.foreground,
          scale: style.fontScale, isScrolling: phase == .hovered)
        if phase != .hovered {
          if isUnread && !isSelected {
            Text("●").fontScale(style.fontScale).foregroundColor(style.activity)
          }
          Text(subtitle).fontScale(style.fontScale).foregroundColor(style.secondaryForeground)
        }
      }
      .padding(EdgeInsets(top: 2, leading: 14, bottom: 2, trailing: 6))
      .sizing(x: .grow, y: .fixed(30))
      .roundedBackground(
        isSelected ? style.selection : phase == .hovered ? style.hover : .clear,
        radius: style.cornerRadius)
      .roundedBorder(
        isSelected ? style.border : .clear, radius: style.cornerRadius,
        width: isSelected ? 1 : 0)
    }.sizing(x: .grow)
  }
}
