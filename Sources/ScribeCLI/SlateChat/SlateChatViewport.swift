// MARK: - Transcript viewport

/// Owns scroll position and follow-mode state for the transcript area.
///
/// Scroll deltas are queued during key processing and resolved once per render
/// frame when the flat transcript and content row count are available.  This
/// avoids double-flattening the transcript (the old code flattened once for
/// scroll, then again for render).
struct TranscriptViewport: Equatable, Sendable {
  /// Line index (in flattened transcript) of the first visible row.
  private(set) var firstVisibleRow: Int = 0
  /// When `true`, the viewport auto-tracks the tail on new output.
  private(set) var followingLive: Bool = true

  /// Accumulated scroll delta to apply on the next `resolve` call.
  private var pendingScrollDelta: Int = 0
  private var pendingGoToTop = false
  private var pendingGoToBottom = false
  /// Absolute flattened-row target to snap to on the next resolve. Used by
  /// the boundary picker to position the cut row near the top of the view.
  /// Overrides delta-based scrolling when set.
  private var pendingScrollToRow: Int?

  // MARK: - Queue operations (call during key processing)

  mutating func queueScroll(by delta: Int) {
    pendingScrollDelta &+= delta
  }

  mutating func queuePageUp() {
    pendingScrollDelta = Int.min  // sentinel for "page up"
  }

  mutating func queuePageDown() {
    pendingScrollDelta = Int.min + 1  // sentinel for "page down"
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

  /// Snap the viewport so `row` (an absolute index in the flattened
  /// transcript) becomes `firstVisibleRow` on the next resolve, clamped to
  /// the available range. Disables live tail-follow. Used by the boundary
  /// picker so arrow keys scroll to the cut.
  mutating func queueScrollToRow(_ row: Int) {
    pendingScrollToRow = row
    pendingScrollDelta = 0
    pendingGoToTop = false
    pendingGoToBottom = false
  }

  // MARK: - Resolve (call once per render frame)

  /// Apply all queued scroll operations and update tail tracking.
  /// Returns the effective `firstVisibleRow` to use for this frame.
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
    case Int.min:  // page up
      applyScroll(delta: -page, flatCount: flatCount, contentRows: contentRows)
    case Int.min + 1:  // page down
      applyScroll(delta: page, flatCount: flatCount, contentRows: contentRows)
    case let delta where delta != 0:
      applyScroll(delta: delta, flatCount: flatCount, contentRows: contentRows)
    default:
      break
    }
    pendingScrollDelta = 0

    return updateTail(flatCount: flatCount, contentRows: contentRows)
  }

  // MARK: - Internal helpers

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
