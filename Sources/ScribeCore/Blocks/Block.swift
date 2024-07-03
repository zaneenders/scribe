public protocol Block {
    associatedtype Component: Block
    @BlockParser var component: Component { get }
}
