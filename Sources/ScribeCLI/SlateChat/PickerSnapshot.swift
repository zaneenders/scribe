import Foundation

/// Snapshot of the boundary-picker overlay the chat host renders in place of
/// the input box during `/fork` and `/tldr`. The host owns the live
/// state; this struct is what the renderer needs to paint a frame.
struct PickerSnapshot: Sendable, Equatable {
  enum Kind: Sendable, Equatable {
    case fork
    case tldr
  }
  var kind: Kind
  /// Ascending list of safe cut indices (see `[ScribeMessage].safeForkBoundaries()`).
  var boundaries: [Int]
  /// Position into `boundaries` of the current selection.
  var cursor: Int
  /// Total messages in the source log — drives the "N / M" display.
  var messageCount: Int
  /// One-line preview of what sits at the current cut (e.g. the first
  /// message that would be discarded, or "<end of session>" when the cut is
  /// `messageCount`). Pre-trimmed by the host.
  var previewText: String

  var currentBoundary: Int {
    guard !boundaries.isEmpty else { return 0 }
    return boundaries[max(0, min(cursor, boundaries.count - 1))]
  }
}
