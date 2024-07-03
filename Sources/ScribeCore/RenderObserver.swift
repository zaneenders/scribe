import Observation

/// The Commands that can be sent to update the state of the ``RenderObserver``.
public enum Command: Codable {
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
public enum Mode: Codable {
    case normal
    case input
}

/// This is the Core engine or model of Scribe it is responsible for updating
/// and maintaining all the state driven by either changes to the blocks or
/// user input from the ``RenderObserver/command(_:)`` function. It is best to
/// keep the expected output size updated before issuing commands with the
/// ``RenderObserver/updateSize(width:height:)``.
public actor Scribe {
    private let block: any Block
    // Holds the current state between render passes. Mostly updated via
    // commands like up, down, left, right, in, out.
    private var graphState: SelectedStateNode? = nil
    /// Displays the current ``Mode`` that the RenderObserver is in.
    private(set) public var mode: Mode = .normal
    private var x: Int
    private var y: Int
    /// The current ``VisibleNode`` mostly used for testing as you have to
    /// manually check when it changes.
    private(set) public var current: VisibleNode
    private let renderer: ((VisibleNode, Int, Int) -> Void)?

    /// The block provided will in a sense be the source of truth for the state
    /// of the system and will not we swapped out for other versions during
    /// run time. The other parameters will be update and used for each frame
    /// update. Well x and y are provided hear it is good calling convention to
    /// pass x and y before each command.
    /// - Parameters:
    ///   - block: The Visual state of the system
    ///   - x: Initial x coordinate to render with.
    ///   - y: Initial y coordinate to render with.
    ///   - renderer: an optional function to be called upon each update. This
    /// is needed if you would like to get updates for changes that are not
    /// triggered by input. Like async network updates.
    // Note I don't love passing in a function. I think some sort of Observation model would be better.
    public init(
        observing block: some Block, width x: Int, height y: Int,
        _ renderer: ((VisibleNode, Int, Int) -> Void)? = nil
    ) async {
        self.x = x
        self.y = y
        self.block = block
        self.current = .text("#init")
        self.renderer = renderer
        startObservation()
    }

    /// Update the current visible region with the x and y
    /// - Parameters:
    ///   - width: The available width to draw in
    ///   - height: The available height to draw in
    public func updateSize(width x: Int, height y: Int) {
        self.x = x
        self.y = y
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
        self.current = getVisible()
        self.graphState = r
    }

    /// Signal the update to rerendered.
    private func startObservation() {
        withObservationTracking {
            self.current = getVisible()
        } onChange: {
            Task(priority: .userInitiated) { await self.startObservation() }
        }
    }

    /// Returns a ``VisibleNode`` containing all the nodes that are visible with in the x and y coordinates given.
    private func getVisible() -> VisibleNode {
        let (state, visible) = self.block.pipeline(
            self.graphState, self.x, self.y)
        self.graphState = state
        if let renderer {
            renderer(visible, self.x, self.y)
        }
        return visible
    }
}
