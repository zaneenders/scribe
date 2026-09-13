import Chroma

/// One linear pass, no Markdown parser, ASCII conversion, or retained cache.
/// Hard wrapping preserves every source character, including whitespace. A tab
/// occupies one cell in this initial literal renderer; it is not expanded in data.
func layoutPlainText(_ text: String, columns: Int, color: Color) -> [VisualLine] {
  let columns = max(1, columns)
  // ASCII byte offsets are also character boundaries. Avoid Swift grapheme
  // indexing for large logs, without changing any bytes or retaining a cache.
  if text.utf8.allSatisfy({ $0 < 128 }) {
    let bytes = Array(text.utf8)
    var lines: [VisualLine] = []
    var start = 0
    var index = 0
    func emit(_ end: Int, separator: String) {
      let value = String(decoding: bytes[start..<end], as: UTF8.self)
      lines.append(VisualLine(
        runs: value.isEmpty ? [] : [VisualRun(text: value, color: color)],
        columnCount: end - start, trailingText: separator))
    }
    while index < bytes.count {
      if bytes[index] == 10 || bytes[index] == 13 {
        let crlf = bytes[index] == 13 && index + 1 < bytes.count && bytes[index + 1] == 10
        emit(index, separator: crlf ? "\r\n" : (bytes[index] == 13 ? "\r" : "\n"))
        index += crlf ? 2 : 1
        start = index
      } else {
        if index - start == columns {
          emit(index, separator: "")
          start = index
        }
        index += 1
      }
    }
    emit(bytes.count, separator: "")
    return lines
  }
  var lines: [VisualLine] = []
  var start = text.startIndex
  var index = start
  var count = 0

  func emit(end: String.Index, separator: String) {
    let value = String(text[start..<end])
    lines.append(VisualLine(
      runs: value.isEmpty ? [] : [VisualRun(text: value, color: color)],
      columnCount: count, trailingText: separator))
  }

  while index < text.endIndex {
    let character = text[index]
    let next = text.index(after: index)
    if character == "\n" || character == "\r" || character == "\r\n" {
      emit(end: index, separator: String(character))
      start = next
      count = 0
    } else {
      if count == columns {
        emit(end: index, separator: "")
        start = index
        count = 0
      }
      count += 1
    }
    index = next
  }
  emit(end: text.endIndex, separator: "")
  return lines
}
