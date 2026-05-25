import Foundation

struct QueuedTraySnapshot: Equatable, Sendable {
  var pending: [String]
  var activeDispatch: ActiveDispatch?
  var batchTotal: Int
  var modelBusy: Bool

  struct ActiveDispatch: Equatable, Sendable {
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
