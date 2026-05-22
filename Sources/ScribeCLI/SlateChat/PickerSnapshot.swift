import Foundation

/// Snapshot of the boundary-picker overlay the chat host renders in place of
/// the input box during `/fork` and `/tldr`. The host owns the live
/// state; this struct is what the renderer needs to paint a frame.
///
/// `.fork` uses a single cursor (`startCursor`) — the cut point.
/// `.tldr` uses two cursors (`startCursor` and `endCursor`) bounding the
/// slice that gets summarized; messages before `start` and at or after `end`
/// are preserved verbatim in the forked session.
struct PickerSnapshot: Sendable, Equatable {
  enum Kind: Sendable, Equatable {
    case fork
    case tldr
  }
  var kind: Kind
  /// Ascending list of safe cut indices (see `[ScribeMessage].safeForkBoundaries()`).
  var boundaries: [Int]
  /// Position into `boundaries` of the start cursor. The only cursor for
  /// `.fork`; the lower bound of the summarized slice for `.tldr`.
  var startCursor: Int
  /// Position into `boundaries` of the end cursor for `.tldr` (upper bound,
  /// exclusive — messages at and after this boundary are kept as the tail).
  /// Nil for `.fork`.
  var endCursor: Int?
  /// Which cursor arrow keys address. Always `false` for `.fork`.
  var activeIsEnd: Bool
  /// Total messages in the source log — drives the "N / M" display.
  var messageCount: Int
  /// One-line preview of the message at the active cursor's cut (e.g. the
  /// first message that would be discarded, or "<end of session>" when the
  /// cut is `messageCount`). Pre-trimmed by the host.
  var previewText: String

  /// Boundary value at the start cursor.
  var startBoundary: Int {
    guard !boundaries.isEmpty else { return 0 }
    return boundaries[max(0, min(startCursor, boundaries.count - 1))]
  }
  /// Boundary value at the end cursor. For `.fork` falls back to
  /// `startBoundary`.
  var endBoundary: Int {
    guard let endCursor, !boundaries.isEmpty else { return startBoundary }
    return boundaries[max(0, min(endCursor, boundaries.count - 1))]
  }
  /// Boundary value at the active cursor.
  var currentBoundary: Int { activeIsEnd ? endBoundary : startBoundary }
}
