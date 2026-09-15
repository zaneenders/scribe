struct ComposerTextLayout {
  struct Row {
    let range: Range<String.Index>
    let start: Int
    let end: Int
    var count: Int { end - start }
  }

  let text: String
  let rows: [Row]

  init(text: String, columns: Int, limit: Int = .max) {
    self.text = text
    var rows: [Row] = []
    var index = text.startIndex
    var startIndex = index
    var offset = 0
    var start = 0
    let columns = max(1, columns)
    while index < text.endIndex {
      let character = text[index]
      let next = text.index(after: index)
      if character == "\n" {
        rows.append(Row(range: startIndex..<index, start: start, end: offset))
        startIndex = next
        start = offset + 1
      } else if offset - start + 1 == columns {
        rows.append(Row(range: startIndex..<next, start: start, end: offset + 1))
        startIndex = next
        start = offset + 1
      }
      if rows.count >= limit {
        self.rows = rows
        return
      }
      index = next
      offset += 1
    }
    if startIndex != text.endIndex || text.isEmpty || text.last == "\n" {
      rows.append(Row(range: startIndex..<text.endIndex, start: start, end: offset))
    }
    self.rows = rows
  }

  func rowIndex(containing caret: Int?) -> Int {
    guard let caret else { return max(0, rows.count - 1) }
    var lower = 0
    var upper = rows.count
    while lower < upper {
      let middle = lower + (upper - lower) / 2
      if rows[middle].start <= caret { lower = middle + 1 } else { upper = middle }
    }
    return max(0, lower - 1)
  }

  func text(for row: Row) -> String { String(text[row.range]) }
}

@MainActor
final class ComposerTextLayoutCache {
  private var revision: UInt64?
  private var columns: Int?
  private var cached: ComposerTextLayout?
  private(set) var buildCount = 0

  private func matches(text: String, revision: UInt64?, columns: Int) -> Bool {
    guard self.columns == columns, let cached else { return false }
    if let revision { return self.revision == revision }
    return self.revision == nil && cached.text == text
  }

  func layout(text: String, revision: UInt64?, columns: Int) -> ComposerTextLayout {
    if matches(text: text, revision: revision, columns: columns), let cached { return cached }
    let layout = ComposerTextLayout(text: text, columns: columns)
    self.revision = revision
    self.columns = columns
    cached = layout
    buildCount += 1
    return layout
  }

  func lineCount(text: String, revision: UInt64?, columns: Int, limit: Int) -> Int {
    if matches(text: text, revision: revision, columns: columns), let cached {
      return min(limit, cached.rows.count)
    }
    return ComposerTextLayout(text: text, columns: columns, limit: limit).rows.count
  }
}
