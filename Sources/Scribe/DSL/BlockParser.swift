/*
The parser for the constructed block tree from the user that is parsed and rendered to the screen.
*/
@resultBuilder
@MainActor
public enum BlockParser {
  public static func buildBlock<Component: Block>(
    _ block: Component
  )
    -> Component
  {
    block
  }

  public static func buildExpression<Component: Block>(
    _ block: Component
  )
    -> Component
  {
    block
  }

  public static func buildBlock<each Component>(
    _ block: repeat each Component
  )
    -> _TupleBlock<repeat each Component>
  where repeat each Component: Block {
    _TupleBlock(repeat each block)
  }

  public static func buildEither<First: Block, Second: Block>(
    first component: First
  ) -> _EitherBlock<First, Second> {
    _EitherBlock<First, Second>(.first(component))
  }

  public static func buildEither<First: Block, Second: Block>(
    second component: Second
  ) -> _EitherBlock<First, Second> {
    _EitherBlock<First, Second>(.second(component))
  }

  public static func buildOptional<Component: Block>(
    _ component: Component?
  )
    -> _ArrayBlock<Component>
  {
    if let component {
      _ArrayBlock<Component>([component])
    } else {
      _ArrayBlock<Component>([])
    }
  }

  public static func buildArray<Component: Block>(
    _ components: [Component]
  )
    -> _ArrayBlock<Component>
  {
    _ArrayBlock<Component>(components)
  }
}
