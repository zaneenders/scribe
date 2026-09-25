import Chroma

public struct ScribeSessionGroupStyle: Sendable {
  public var foreground: Color
  public var hoveredForeground: Color
  public var count: Color
  public var newSession: Color
  public var hoverBackground: Color
  public var fontScale: Float
  public var cornerRadius: Float

  public init(
    foreground: Color, hoveredForeground: Color, count: Color, newSession: Color,
    hoverBackground: Color, fontScale: Float, cornerRadius: Float = 0
  ) {
    self.foreground = foreground
    self.hoveredForeground = hoveredForeground
    self.count = count
    self.newSession = newSession
    self.hoverBackground = hoverBackground
    self.fontScale = fontScale
    self.cornerRadius = cornerRadius
  }
}

public struct ScribeSessionGroup: Block {
  let id: String
  let title: String
  let count: Int
  let isCollapsed: Bool
  let style: ScribeSessionGroupStyle
  let onToggle: @MainActor () -> Void
  let onNewSession: @MainActor () -> Void

  public init(
    id: String, title: String, count: Int, isCollapsed: Bool,
    style: ScribeSessionGroupStyle,
    onToggle: @escaping @MainActor () -> Void,
    onNewSession: @escaping @MainActor () -> Void
  ) {
    self.id = id
    self.title = title
    self.count = count
    self.isCollapsed = isCollapsed
    self.style = style
    self.onToggle = onToggle
    self.onNewSession = onNewSession
  }

  @MainActor public var body: some Block {
    HStack(spacing: 4) {
      Interactive(action: onToggle) { phase in
        HStack(spacing: 5) {
          Text(isCollapsed ? ">" : "v")
            .fontScale(style.fontScale).foregroundColor(style.foreground)
          MarqueeText(
            title, id: id,
            color: phase == .hovered ? style.hoveredForeground : style.foreground,
            scale: style.fontScale, isScrolling: phase == .hovered)
          Text("\(count)").fontScale(style.fontScale).foregroundColor(style.count)
        }
        .padding(EdgeInsets(top: 7, leading: 8, bottom: 5, trailing: 4))
        .sizing(x: .grow)
        .roundedBackground(
          phase == .hovered ? style.hoverBackground : .clear, radius: style.cornerRadius)
      }
      Interactive(action: onNewSession) { phase in
        VStack(spacing: 0) {
          Spacer()
          HStack(spacing: 0) {
            Spacer()
            Text("+").fontScale(style.fontScale).foregroundColor(style.newSession)
            Spacer()
          }.sizing(x: .grow)
          Spacer()
        }
        .sizing(x: .fixed(28), y: .fixed(28))
        .roundedBackground(
          phase == .idle ? .clear : style.hoverBackground, radius: style.cornerRadius)
      }
      .padding(EdgeInsets(top: 1, leading: 0, bottom: 1, trailing: 4))
    }.sizing(x: .grow)
  }
}
