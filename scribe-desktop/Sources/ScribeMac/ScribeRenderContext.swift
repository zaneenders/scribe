import Chroma

@MainActor
enum ScribeBlockContext {
  static var current: BlockContext?
}

struct BlockContextBridge<Content: Block>: LayoutPreparingBlock {
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
    let previous = ScribeBlockContext.current
    ScribeBlockContext.current = context
    defer { ScribeBlockContext.current = previous }
    return BlockEngine.measure(content, proposal: proposal, context: context)
  }

  @MainActor func prepareLayout(context: BlockContext) -> BlockEngine.Resolved {
    var child: BlockEngine.Resolved?
    return BlockEngine.Resolved(
      expandsHorizontally: { expandsHorizontally },
      expandsVertically: { expandsVertically },
      measure: { sizeThatFits($0, context: context) },
      register: { rect in
        let previous = ScribeBlockContext.current
        ScribeBlockContext.current = context
        defer { ScribeBlockContext.current = previous }
        prepare(context)
        child = BlockEngine.prepare(content, context: context)
        child?.register(in: rect)
        finish(context)
      },
      paint: { list, rect in
        let previous = ScribeBlockContext.current
        ScribeBlockContext.current = context
        defer { ScribeBlockContext.current = previous }
        child?.paint(into: &list, in: rect)
      })
  }
}
