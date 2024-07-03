import Observation

/// The Commands that can be sent to update the state of the ``RenderObserver``.
public enum Command {
    case `in`
    case `out`
    case up
    case down
    case left
    case right
    case unsafeInput(String)
}

/// The Modes in which RenderObserver can be in. This effects how input is
/// interpreted
public enum Mode {
    case normal
    case input
}

/// This is going to be the core of what makes ChromaShell actually work as it
/// survive where the translation and updates to the given Block are processed
/// and passed to the terminal. This may get moved out of rendering and into
/// Controller or Engine.
public actor RenderObserver {
    private let block: any Block
    // Holds the current state between render passes. Mostly updated via
    // commands like up, down, left, right, in, out.
    private var graphState: SelectedStateNode? = nil
    /// Displays the current ``Mode`` that the RenderObserver is in.
    private(set) public var mode: Mode = .normal
    private var renderer: any Renderer.Type
    private var x: Int
    private var y: Int

    /// The block provided will in a sense be the source of truth for the state
    /// of the system and will not we swapped out for other versions during
    /// run time. The other parameters will be update and used for each frame
    /// update. Well x and y are provided hear it is good calling convention to
    /// pass x and y before each command.
    /// - Parameters:
    ///   - block: The Visual state of the system
    ///   - x: Initial x coordinate to render with.
    ///   - y: Initial y coordinate to render with.
    ///   - renderer: A type that will be constructed with the current
    /// ``VisibleNode`` then render called with the current x and y values.
    /// Which if updated before the command call will not change between there
    /// and when they are passed to render.
    public init(
        _ block: some Block, _ x: Int, _ y: Int, _ renderer: any Renderer.Type
    ) {
        self.x = x
        self.y = y
        self.renderer = renderer
        self.block = block
    }

    public func updateSize(_ x: Int, _ y: Int) {
        self.x = x
        self.y = y
    }

    /// Signal the update to rerendered.
    // Maybe this should go in init?
    public func startObservation() {
        withObservationTracking {
            render()
        } onChange: {
            Task(priority: .userInitiated) { await self.startObservation() }
        }
    }

    /// Used to interact with the graph.
    /// Examples: changing state, pressing buttons, changing position
    public func command(_ cmd: Command) {

        // First render() takes care of optional
        let (r, m) = self.graphState!.apply(command: cmd)
        switch (self.mode, cmd) {
        case (.input, .out):
            self.mode = .normal
        default:
            self.mode = m
        }
        render()
        self.graphState = r
    }

    /// Draw to the screen, put the available data on the terminal.
    public func render() {
        let (state, visible) = self.block.pipeline(
            self.graphState, self.x, self.y)
        self.graphState = state
        renderer.init(visible).render(x, y)
    }
}
