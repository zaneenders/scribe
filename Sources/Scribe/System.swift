/// Name space for abstractions over the Operating System
enum System {
    /// A global clock allocation for timing in the system.
    static let clock: ContinuousClock = ContinuousClock()
}
