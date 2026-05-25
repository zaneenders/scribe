import Foundation

struct PickerSnapshot: Sendable, Equatable {
  enum Kind: Sendable, Equatable {
    case fork
    case tldr
  }
  var kind: Kind

  var boundaries: [Int]

  var startCursor: Int

  var endCursor: Int?

  var activeIsEnd: Bool

  var messageCount: Int

  var previewText: String

  var startBoundary: Int {
    guard !boundaries.isEmpty else { return 0 }
    return boundaries[max(0, min(startCursor, boundaries.count - 1))]
  }

  var endBoundary: Int {
    guard let endCursor, !boundaries.isEmpty else { return startBoundary }
    return boundaries[max(0, min(endCursor, boundaries.count - 1))]
  }

  var currentBoundary: Int { activeIsEnd ? endBoundary : startBoundary }
}
