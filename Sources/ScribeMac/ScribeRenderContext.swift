import Chroma

@MainActor
enum ScribeRenderContext {
  static var current: BlockContext?
}

struct RenderContextBridge<Content: Block>: PrimitiveBlock {
  var focusRule: FocusRule { .container }
  let content: Content
  let prepare: @MainActor (BlockContext) -> Void
  var finish: @MainActor (BlockContext) -> Void = { _ in }

  @MainActor var expandsHorizontally: Bool {
    BlockEngine.expandsHorizontally(content)
  }

  @MainActor var expandsVertically: Bool {
    BlockEngine.expandsVertically(content)
  }

  @MainActor func sizeThatFits(_ proposal: Size, context: BlockContext) -> Size {
    ScribeRenderContext.current = context
    return BlockEngine.measure(content, proposal: proposal, context: context)
  }

  @MainActor func draw(into drawList: inout DrawList, in rect: Rect, context: BlockContext) {
    ScribeRenderContext.current = context
    prepare(context)
    BlockEngine.draw(content, into: &drawList, in: rect, context: context)
    finish(context)
  }
}
