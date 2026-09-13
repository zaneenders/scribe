import Chroma
import Testing
@testable import ScribeBlocks

struct PlainTextLayoutTests {
  @Test func preservesLiteralSourceAcrossWrapping() {
    let source = "  # heading\r\n\t**literal**  café 👩‍💻\n```swift\nx\n```\r尾\n"
    for width in [1, 8, 80] {
      let lines = layoutPlainText(source, columns: width, color: MacTheme().textPrimary)
      let restored = lines.map { $0.runs.map(\.text).joined() + $0.trailingText }.joined()
      #expect(restored == source)
      #expect(lines.allSatisfy { $0.kind == .plain && $0.columnCount <= width })
    }
  }

  @Test func preservesBlankLinesAndExactWidthNewlines() {
    let lines = layoutPlainText("abcd\n\nend", columns: 4, color: MacTheme().textPrimary)
    #expect(lines.map(\.columnCount) == [4, 0, 3])
    #expect(lines.map(\.trailingText) == ["\n", "\n", ""])
    #expect(layoutPlainText("", columns: 0, color: MacTheme().textPrimary).count == 1)
  }
}
