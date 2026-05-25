import Foundation

/// Snapshot of the steering queue for the tray between transcript and input.
struct QueuedTraySnapshot: Equatable, Sendable {
  /// Messages still waiting in ``SessionHarness`` (oldest first).
  var pending: [String]
  /// Message popped and sent to the agent (empty Enter while busy).
  var activeDispatch: ActiveDispatch?
  /// Total messages in this queue batch (including any already dispatched).
  var batchTotal: Int
  /// Whether the model is currently running a turn.
  var modelBusy: Bool

  struct ActiveDispatch: Equatable, Sendable {
    /// 1-based index within ``batchTotal``.
    var index: Int
    var text: String
  }

  var isEmpty: Bool {
    pending.isEmpty && activeDispatch == nil
  }

  init(
    pending: [String] = [],
    activeDispatch: ActiveDispatch? = nil,
    batchTotal: Int = 0,
    modelBusy: Bool = false
  ) {
    self.pending = pending
    self.activeDispatch = activeDispatch
    self.batchTotal = batchTotal
    self.modelBusy = modelBusy
  }
}
