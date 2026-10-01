import Chroma

public struct ScribeTranscriptPanelStyle: Sendable {
  public var background: Color
  public var border: Color
  public var padding: Float
  public var cornerRadius: Float
  public var spacing: Float

  public init(
    background: Color, border: Color, padding: Float = 14,
    cornerRadius: Float = 0, spacing: Float = 7
  ) {
    self.background = background
    self.border = border
    self.padding = padding
    self.cornerRadius = cornerRadius
    self.spacing = spacing
  }
}

public struct ScribeTranscriptPanel<Header: Block, Content: Block>: Block {
  let style: ScribeTranscriptPanelStyle
  let header: Header
  let content: Content

  public init(style: ScribeTranscriptPanelStyle, header: Header, content: Content) {
    self.style = style
    self.header = header
    self.content = content
  }

  @MainActor public var body: some Block {
    VStack(spacing: style.spacing) {
      header
      content
    }
    .padding(style.padding)
    .sizing(x: .grow)
    .roundedBackground(style.background, radius: style.cornerRadius)
    .roundedBorder(style.border, radius: style.cornerRadius)
  }
}
