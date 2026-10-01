import Chroma
import Testing

@testable import ScribeBlocks

@Suite("Markdown Unicode preservation")
struct MacMarkdownSanitizationTests {
  private func renderedText(_ source: String, columns: Int = 100) -> String {
    let block = MarkdownText(markdown: source, theme: MacTheme(), baseColor: .white, scale: 1)
    let metrics = FontMetrics()
    let lines = block.lines(forWidth: Float(columns) * metrics.cellAdvance, metrics: metrics)
    let layout = MarkdownLayout(lines: lines, lineHeight: 10, cellWidth: 5, scale: 1)
    return layout.textInRange(
      from: (line: 0, column: 0), to: (line: max(0, lines.count - 1), column: lines.last?.columnCount ?? 0))
  }

  @Test func preservesTreeDiagramsInCodeBlocks() {
    let tree = """
      One Scribe client application
        ├── Local window  -> local backend
        ├── Workstation   -> SSH tunnel -> workstation backend
        └── Server        -> SSH tunnel -> server backend
      """
    #expect(renderedText("```\n\(tree)\n```") == tree)
    #expect(sanitizeASCII(tree) == tree)
    #expect(segmentMarkdown(sanitizeASCII("```\n\(tree)\n```")) == [.code(language: nil, code: tree)])
  }

  @Test func preservesEntireBoxDrawingBlock() {
    let symbols = String((0x2500...0x257F).map { Character(String(UnicodeScalar($0)!)) })
    #expect(renderedText(symbols, columns: 200) == symbols)
    #expect(sanitizeASCII(symbols) == symbols)
  }

  @Test func preservesUnicodeThroughRenderingAndSelection() {
    let text = "“café” → … — 中文 e\u{0301} 👩‍💻 🙂"
    #expect(renderedText(text) == text)
    #expect(renderedText(text, columns: 8) == text)
    #expect(renderedText("```\n\(text)\n```") == text)
  }

  @Test func editableFieldSanitizationIsUnchanged() {
    #expect(sanitizeASCII("“hello” → …\t🙂") == "\"hello\" -> ...    ?")
    #expect(sanitizeASCII("plain ASCII\ntext") == "plain ASCII\ntext")
  }
}
