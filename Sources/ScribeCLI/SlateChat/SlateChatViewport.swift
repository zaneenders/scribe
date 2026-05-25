struct TranscriptViewport: Equatable, Sendable {

  private(set) var firstVisibleRow: Int = 0

  private(set) var followingLive: Bool = true

  private var pendingScrollDelta: Int = 0
  private var pendingGoToTop = false
  private var pendingGoToBottom = false

  private var pendingScrollToRow: Int?

  mutating func queueScroll(by delta: Int) {
    pendingScrollDelta &+= delta
  }

  mutating func queuePageUp() {
    pendingScrollDelta = Int.min
  }

  mutating func queuePageDown() {
    pendingScrollDelta = Int.min + 1
  }

  mutating func queueGoToTop() {
    pendingGoToTop = true
    pendingGoToBottom = false
    pendingScrollDelta = 0
  }

  mutating func queueGoToBottom() {
    pendingGoToBottom = true
    pendingGoToTop = false
    pendingScrollDelta = 0
  }

  mutating func queueScrollToRow(_ row: Int) {
    pendingScrollToRow = row
    pendingScrollDelta = 0
    pendingGoToTop = false
    pendingGoToBottom = false
  }

  mutating func resolve(flatCount: Int, contentRows: Int) -> Int {
    if pendingGoToTop {
      followingLive = false
      firstVisibleRow = 0
      pendingGoToTop = false
    }
    if pendingGoToBottom {
      followingLive = true
      pendingGoToBottom = false
    }
    if let target = pendingScrollToRow {
      followingLive = false
      let maxTailStart = max(0, flatCount &- contentRows)
      firstVisibleRow = min(max(0, target), maxTailStart)
      pendingScrollToRow = nil
      return updateTail(flatCount: flatCount, contentRows: contentRows)
    }

    let page = max(1, contentRows)

    switch pendingScrollDelta {
    case Int.min:
      applyScroll(delta: -page, flatCount: flatCount, contentRows: contentRows)
    case Int.min + 1:
      applyScroll(delta: page, flatCount: flatCount, contentRows: contentRows)
    case let delta where delta != 0:
      applyScroll(delta: delta, flatCount: flatCount, contentRows: contentRows)
    default:
      break
    }
    pendingScrollDelta = 0

    return updateTail(flatCount: flatCount, contentRows: contentRows)
  }

  private mutating func applyScroll(delta: Int, flatCount: Int, contentRows: Int) {
    let maxTailStart = max(0, flatCount &- contentRows)

    if delta < 0 {
      if followingLive {
        followingLive = false
        firstVisibleRow = max(0, maxTailStart &+ delta)
      } else {
        firstVisibleRow = max(0, firstVisibleRow &+ delta)
      }
    } else {
      firstVisibleRow = min(firstVisibleRow &+ delta, maxTailStart)
      if firstVisibleRow >= maxTailStart {
        followingLive = true
      }
    }
  }

  private mutating func updateTail(flatCount: Int, contentRows: Int) -> Int {
    let maxTailStart = max(0, flatCount &- contentRows)
    if followingLive {
      firstVisibleRow = maxTailStart
    } else {
      firstVisibleRow = min(firstVisibleRow, maxTailStart)
    }
    return firstVisibleRow
  }
}
