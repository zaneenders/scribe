import Chroma

/// Makes Chroma's explicit render context available to app-level actions that
/// run outside a primitive's `draw` call, regardless of the active backend.
@MainActor
enum ScribeRenderContext {
  static var current: RenderContext?
  static var activeTextInput: WidgetID?
}

struct RenderContextBridge<Content: Block>: PrimitiveBlock {
  let content: Content
  let prepare: @MainActor (RenderContext) -> Void

  @MainActor var expandsHorizontally: Bool {
    BlockEngine.expandsHorizontally(content)
  }

  @MainActor var expandsVertically: Bool {
    BlockEngine.expandsVertically(content)
  }

  @MainActor func sizeThatFits(_ proposal: Size, context: RenderContext) -> Size {
    ScribeRenderContext.current = context
    return BlockEngine.measure(content, proposal: proposal, context: context)
  }

  @MainActor func draw(into drawList: inout DrawList, in rect: Rect, context: RenderContext) {
    ScribeRenderContext.current = context
    prepare(context)
    BlockEngine.draw(content, into: &drawList, in: rect, context: context)
  }
}
