/// This type is responsible for output to the display of the current setup.
public protocol Renderer {
    /// This will be called per frame so keep the work between initialization
    /// and render light.
    init(_ graph: VisibleNode)
    /// Outputs the actual image to the display.
    func render(_ x: Int, _ y: Int)
}
