import ScribeCore
import SlateCore
import Testing

@testable import ScribeCLI

private func renderIncremental(
  chunks: [String],
  baseFG: TerminalRGB = ScribePalette.cyan,
  baseBold: Bool = false
) -> [[TLine]] {
  let renderer = SwiftMarkdownRenderer()
  var buffer = ""
  var snapshots: [[TLine]] = []
  for chunk in chunks {
    buffer += chunk
    let snapshot = renderer.render(text: buffer, baseFG: baseFG, baseBold: baseBold)
    snapshots.append(snapshot)
  }
  return snapshots
}

private func render(
  _ text: String,
  baseFG: TerminalRGB = ScribePalette.cyan,
  baseBold: Bool = false
) -> [TLine] {
  SwiftMarkdownRenderer().render(text: text, baseFG: baseFG, baseBold: baseBold)
}

private func plain(_ line: TLine) -> String {
  line.spans.map(\.text).joined()
}

private func plainLines(_ lines: [TLine]) -> [String] {
  lines.map { plain($0) }
}

@Suite
struct MarkdownRendererTests {

  @Test func emptyString() {
    let lines = render("")
    #expect(lines.isEmpty)
  }

  @Test func whitespaceOnly() {
    let lines = render("   \n  \n  ")
    #expect(lines.allSatisfy { $0.spans.allSatisfy { $0.text.trimmingCharacters(in: .whitespaces).isEmpty } })
  }

  @Test func debugStreamingConsistency() {
    let md =
      "### 4. O(n²) re-parsing on every SSE chunk\n\n`SwiftMarkdownRenderer.render()` calls `Document(parsing: text)` on the entire accumulated buffer every time a chunk arrives. For a 10,000-character response arriving in 100-character chunks, that’s ~100 full document parses.\n\n1. Set assistantSectionStartIndex = sink.lines.count when the answer section starts\n2. On each chunk: sink.lines.removeLast(count - startIdx) then re-append all rendered lines\n3. Clear it on finalize/interrupt\n\n### 7. &+= overflow operator is surprising\n\n```swift\nsink.lineGeneration &+= 1\n```\n\nThis wraps on overflow rather than trapping.\n\n---\n\n## 🟢 Nit / Style\n\n### 8. Comment typo: \"Vibrate Spring\"\n\n```swift\n// MARK: - Markdown styling (Vibrate Spring)\n```\n\n→ \"Vibrant Spring\" or \"Vibrant Spectrum\"?\n\n### 9. Root directory clutter\n\n`fuzz.md`, `table.md`, `swift-summary.md` at the repo root.\n\n### 10. Reasoning color change: yellowBright → grayLight\n\n```swift\n- case .reasoning: (ScribePalette.yellowBright, true)\n+ case .reasoning: (ScribePalette.grayLight, false)\n```\n\nThis de-emphasizes reasoning text.\n\n### 11. Duplicate guard + if in visitTable\n\nThe guard `!allRows.isEmpty` and guard `columnCount > 0` are immediately followed by `let columnCount = allRows.map { $0.count }.max() ?? 0` which already handles the empty case.\n\n### 12. swift-markdown minimum version\n\nNo Package.resolved pin for swift-markdown.\n"
    let oneShot = render(md)
    let chunks = md.map(String.init)
    let snapshots = renderIncremental(chunks: chunks)
    let final = snapshots.last!
    if oneShot != final {
      print("MISMATCH!")
      print("One-shot lines: \(oneShot.count)")
      print("Final lines: \(final.count)")
      let maxLines = max(oneShot.count, final.count)
      for i in 0..<maxLines {
        let a = i < oneShot.count ? oneShot[i].spans.map(\.text).joined() : "<missing>"
        let b = i < final.count ? final[i].spans.map(\.text).joined() : "<missing>"
        if a != b {
          print("Line \(i):")
          print("  one-shot: '\(a)'")
          print("  final:    '\(b)'")
        }
      }
    }
    #expect(oneShot == final)
  }

  @Test func debugSinkColors() {
    let messages: [ScribeMessage] = [
      ScribeMessage(role: .user, content: "test"),
      ScribeMessage(role: .assistant, content: "### 4. O(n²) re-parsing\n1. hello world\n"),
    ]
    let completed = renderMessagesToTranscript(
      messages, theme: .default, renderer: SwiftMarkdownRenderer())

    func firstColor(of line: TLine) -> String {
      if let first = line.spans.first {
        switch first.fg {
        case ScribePalette.cyan: return "cyan"
        case ScribePalette.markdownHeading: return "heading"
        case ScribePalette.markdownHeadingPrefix: return "headingPrefix"
        case ScribePalette.markdownListMarker: return "listMarker"
        default: return "other"
        }
      }
      return "empty"
    }

    let expected: [(color: String, text: String)] = [
      ("other", "you:"),
      ("other", "  test"),
      ("empty", ""),
      ("other", "scribe:"),
      ("other", "  · answer"),
      ("headingPrefix", "### 4. O(n²) re-parsing"),
      ("listMarker", "1. hello world"),
      ("empty", ""),
    ]

    #expect(completed.count == expected.count)
    for (i, (ec, et)) in expected.enumerated() {
      let text = completed[i].spans.map(\.text).joined()
      #expect(
        firstColor(of: completed[i]) == ec, "line \(i) color: expected \(ec), got \(firstColor(of: completed[i]))")
      #expect(text == et, "line \(i) text: expected '\(et)', got '\(text)'")
    }
  }

  @Test func singleCharacter() {
    let lines = render("x")
    #expect(plainLines(lines) == ["x"])
  }

  @Test func streamingSingleCharChunks() {
    let text = "Hello **world** with `code`"
    let chunks = text.map { String($0) }
    let snapshots = renderIncremental(chunks: chunks)
    let final = snapshots.last!
    let oneShot = render(text)
    #expect(final == oneShot)
  }

  @Test func streamingWordByWord() {
    let words = "The quick **brown** fox *jumps* over the `lazy` dog"
      .split(separator: " ").map { String($0) + " " }
    let snapshots = renderIncremental(chunks: words)
    let oneShot = render(words.joined())
    #expect(snapshots.last! == oneShot)
  }

  @Test func streamingSplitMidDelimiter() {

    let chunks = ["Hello **bo", "ld** world"]
    let snapshots = renderIncremental(chunks: chunks)
    let oneShot = render("Hello **bold** world")
    #expect(snapshots.last! == oneShot)
  }

  @Test func streamingSplitMidBacktick() {
    let chunks = ["`co", "de`"]
    let snapshots = renderIncremental(chunks: chunks)
    let oneShot = render("`code`")
    #expect(snapshots.last! == oneShot)
  }

  @Test func streamingCodeBlockArrivesInChunks() {
    let chunks = ["```swift\nlet x", " = 1\nprint(x)\n```"]
    let snapshots = renderIncremental(chunks: chunks)
    #expect(!snapshots.last!.isEmpty)
  }

  @Test func headingsAllLevels() {
    for level in 1...6 {
      let prefix = String(repeating: "#", count: level)
      let lines = render("\(prefix) Heading \(level)")
      let text = plainLines(lines)
      #expect(text.first?.hasPrefix(prefix) == true)
    }
  }

  @Test func headingWithInlineFormatting() {
    let lines = render("# Hello **bold** and *italic*")
    let allSpans = lines.flatMap(\.spans)
    #expect(allSpans.contains { $0.bold && $0.text.contains("bold") })
    #expect(allSpans.contains { $0.fg == ScribePalette.markdownItalic })
  }

  @Test func boldAndItalicCombined() {
    let lines = render("This is ***bold italic*** and **bold** and *italic*")
    let allSpans = lines.flatMap(\.spans)
    #expect(allSpans.contains { $0.bold })
    #expect(allSpans.contains { $0.fg == ScribePalette.markdownItalic })
  }

  @Test func strikethrough() {
    let lines = render("This is ~~struck~~ text")
    let allSpans = lines.flatMap(\.spans)
    #expect(allSpans.contains { $0.fg == ScribePalette.gray && $0.text.contains("struck") })
  }

  @Test func inlineCode() {
    let lines = render("Use `let x = 1` to bind")
    let allSpans = lines.flatMap(\.spans)
    #expect(allSpans.contains { $0.fg == ScribePalette.markdownCode && $0.text.contains("let x = 1") })
  }

  @Test func inlineCodeWithMarkdownInside() {

    let lines = render("`**not bold**`")
    let allSpans = lines.flatMap(\.spans)
    #expect(allSpans.contains { $0.text.contains("**not bold**") && $0.fg == ScribePalette.markdownCode })
  }

  @Test func backtickInsideCode() {
    let lines = render("Use `` `nested` `` syntax")
    #expect(!lines.isEmpty)
  }

  @Test func fencedCodeBlock() {
    let lines = render("```\nhello\nworld\n```")
    let p = plainLines(lines)
    #expect(p.contains("```"))
    #expect(p.contains("hello"))
    #expect(p.contains("world"))
  }

  @Test func fencedCodeBlockWithLanguage() {
    let lines = render("```swift\nlet x = 1\n```")
    let p = plainLines(lines)
    #expect(p.contains("```swift"))
    #expect(p.contains("let x = 1"))
  }

  @Test func codeBlockEmpty() {
    let lines = render("```\n```")
    let p = plainLines(lines)
    #expect(p.filter { $0 == "```" }.count == 2)
  }

  @Test func codeBlockWithTildes() {
    let lines = render("~~~\ncode here\n~~~")
    #expect(!lines.isEmpty)
  }

  @Test func blockQuote() {
    let lines = render("> This is a quote")
    let allSpans = lines.flatMap(\.spans)
    #expect(allSpans.contains { $0.fg == ScribePalette.markdownBlockquote })
  }

  @Test func blockQuoteMultiLine() {
    let lines = render("> line one\n> line two")
    let p = plainLines(lines)
    #expect(p.contains { $0.contains("line one") })
    #expect(p.contains { $0.contains("line two") })
  }

  @Test func blockQuoteWithInline() {
    let lines = render("> **bold** and *italic*")
    let allSpans = lines.flatMap(\.spans)
    #expect(allSpans.contains { $0.bold })
  }

  @Test func unorderedList() {
    let lines = render("- item one\n- item two\n- item three")
    let p = plainLines(lines)
    #expect(p.contains { $0.contains("- ") })
  }

  @Test func orderedList() {
    let lines = render("1. first\n2. second\n3. third")
    let p = plainLines(lines)
    #expect(p.contains { $0.contains("1. ") })
  }

  @Test func orderedListCustomStart() {
    let lines = render("5. five\n6. six")
    let p = plainLines(lines)
    #expect(p.contains { $0.contains("5. ") })
  }

  @Test func listWithInlineFormatting() {
    let lines = render("- **bold item**\n- *italic item*\n- `code item`")
    let allSpans = lines.flatMap(\.spans)
    #expect(allSpans.contains { $0.bold })
    #expect(allSpans.contains { $0.fg == ScribePalette.markdownItalic })
    #expect(allSpans.contains { $0.fg == ScribePalette.markdownCode })
  }

  @Test func nestedList() {
    let lines = render("- parent\n  - child\n  - child 2\n- parent 2")
    #expect(!lines.isEmpty)
  }

  @Test func tableBasic() {
    let md = "| Name | Age |\n| --- | --- |\n| Alice | 30 |\n| Bob | 25 |\n"
    let lines = render(md)
    let allText = lines.flatMap(\.spans).map(\.text).joined()
    #expect(allText.contains("Alice"))
    #expect(allText.contains("Bob"))
    #expect(allText.contains("30"))
    #expect(allText.contains("25"))

    #expect(allText.contains("Name"))
    #expect(allText.contains("Age"))
  }

  @Test func tableSingleCell() {
    let md = "| only |\n| --- |\n| val |\n"
    let lines = render(md)
    let allText = lines.flatMap(\.spans).map(\.text).joined()
    #expect(allText.contains("only"))
    #expect(allText.contains("val"))
  }

  @Test func tableManyColumns() {
    let headers = (0..<10).map { "C\($0)" }
    let headerRow = "| " + headers.joined(separator: " | ") + " |"
    let sepRow = "|" + headers.map { _ in " --- |" }.joined()
    let dataRow = "| " + headers.map { _ in "x" }.joined(separator: " | ") + " |"
    let lines = render("\(headerRow)\n\(sepRow)\n\(dataRow)\n")
    let allText = lines.flatMap(\.spans).map(\.text).joined()
    #expect(allText.contains("C0"))
    #expect(allText.contains("C9"))
    #expect(allText.contains("x"))
  }

  @Test func tableBoxDrawingBorders() {
    let md = "| A | B |\n|---|---|\n| 1 | 2 |\n"
    let lines = render(md)
    let p = plainLines(lines)
    #expect(p.contains { $0.hasPrefix("┌") })
    #expect(p.contains { $0.hasPrefix("├") })
    #expect(p.contains { $0.hasPrefix("└") })
    #expect(p.contains { $0.hasSuffix("┐") })
    #expect(p.contains { $0.hasSuffix("┤") })
    #expect(p.contains { $0.hasSuffix("┘") })
    #expect(p.contains { $0.contains("│") })
  }

  @Test func tableHeaderIsBold() {
    let md = "| Name |\n| --- |\n| Alice |\n"
    let lines = render(md)
    let allSpans = lines.flatMap(\.spans)
    let headerSpans = allSpans.filter { $0.text.contains("Name") }
    #expect(headerSpans.allSatisfy { $0.bold })
  }

  @Test func tableColumnPadding() {
    let md = "| Name | Age |\n| --- | --- |\n| A | 100 |\n"
    let lines = render(md)

    let p = plainLines(lines)
    let dataRow = p.first { $0.contains("│ A") }
    #expect(dataRow != nil)
  }

  @Test func tableWithInlineFormattingInCells() {
    let md = "| Feature | Status |\n| --- | --- |\n| **Bold** | `code` |\n| *italic* | plain |\n"
    let lines = render(md)
    let allSpans = lines.flatMap(\.spans)
    #expect(allSpans.contains { $0.bold && $0.text.contains("Bold") })
    #expect(allSpans.contains { $0.fg == ScribePalette.markdownCode && $0.text.contains("code") })
    #expect(allSpans.contains { $0.fg == ScribePalette.markdownItalic && $0.text.contains("italic") })
  }

  @Test func tableEmptyCells() {
    let md = "| A | B | C |\n|---|---|---|\n|   | x |   |\n| y |   | z |\n"
    let lines = render(md)
    let p = plainLines(lines)
    #expect(p.contains { $0.contains("x") })
    #expect(p.contains { $0.contains("y") })
    #expect(p.contains { $0.contains("z") })
  }

  @Test func tableStreaming() {
    let md = "| Name | Age |\n| --- | --- |\n| Alice | 30 |\n"
    let chunks = md.map(String.init)
    let snapshots = renderIncremental(chunks: chunks)
    let oneShot = render(md)
    #expect(snapshots.last! == oneShot)
  }

  @Test func tableHeaderOnly() {
    let md = "| Name | Age |\n| --- | --- |\n"
    let lines = render(md)
    let p = plainLines(lines)
    #expect(p.contains { $0.contains("Name") })
    #expect(p.contains { $0.contains("Age") })
    #expect(p.contains { $0.hasPrefix("┌") })
    #expect(p.contains { $0.hasPrefix("└") })
  }

  @Test func tableMismatchedColumns() {

    let md = "| A | B | C |\n|---|---|---|\n| 1 | 2 |\n"
    let lines = render(md)
    let p = plainLines(lines)
    #expect(p.contains { $0.contains("1") })
    #expect(p.contains { $0.contains("2") })

    let dataRow = p.first { $0.contains("1") && $0.contains("2") }
    #expect(dataRow != nil)
  }

  @Test func tableWideContent() {
    let md = "| Short | VeryLongHeaderName |\n| --- | --- |\n| x | y |\n"
    let lines = render(md)
    let p = plainLines(lines)

    let dataRow = p.first { $0.contains("x") && $0.contains("y") }
    #expect(dataRow != nil)

    #expect(p.contains { $0.contains("Short") })
  }

  @Test func tableColumnPaddingExact() {
    let md = "| Name | Age |\n| --- | --- |\n| A | 100 |\n"
    let lines = render(md)
    let p = plainLines(lines)

    let dataRow = p.first { $0.contains("│ A ") }
    #expect(dataRow != nil)
  }

  @Test func link() {
    let lines = render("[Click here](https://example.com)")
    let allSpans = lines.flatMap(\.spans)
    #expect(allSpans.contains { $0.fg == ScribePalette.markdownLink && $0.text.contains("Click here") })
  }

  @Test func image() {
    let lines = render("![alt text](image.png)")
    let allSpans = lines.flatMap(\.spans)
    #expect(allSpans.contains { $0.text.contains("alt text") })
  }

  @Test func thematicBreak() {

    let lines = render("before\n\n---\nafter")
    #expect(plainLines(lines).contains("---"))
  }

  @Test func thematicBreakVariants() {
    for hr in ["***", "___", "---", "* * *", "- - -"] {
      let lines = render("before\n\n\(hr)\nafter")
      let p = plainLines(lines)
      #expect(p.contains { $0.contains("---") || $0.contains("***") || $0.contains("___") })
    }
  }

  @Test func inlineHTML() {
    let lines = render("Some <b>bold</b> text")
    let allSpans = lines.flatMap(\.spans)
    #expect(allSpans.contains { $0.fg == ScribePalette.gray && $0.text.contains("<b>") })
  }

  @Test func htmlBlock() {
    let lines = render("<div>\n  hello\n</div>")
    let allSpans = lines.flatMap(\.spans)
    #expect(allSpans.contains { $0.fg == ScribePalette.gray })
  }

  @Test func hardBreak() {
    let lines = render("line one  \nline two")
    #expect(plainLines(lines).count >= 2)
  }

  @Test func softBreak() {
    let lines = render("line one\nline two")
    #expect(plainLines(lines).count >= 2)
  }

  @Test func singleAsteriskLiteral() {
    let lines = render("This is a * literal asterisk")
    #expect(!lines.isEmpty)
  }

  @Test func unmatchedDoubleAsterisk() {
    let lines = render("Hello **world")
    #expect(!lines.isEmpty)
  }

  @Test func unmatchedBacktick() {
    let lines = render("Hello `world")
    #expect(!lines.isEmpty)
  }

  @Test func unmatchedItalic() {
    let lines = render("Hello *world")
    #expect(!lines.isEmpty)
  }

  @Test func asteriskThenBold() {
    let lines = render("*italic* and **bold**")
    let allSpans = lines.flatMap(\.spans)
    #expect(allSpans.contains { $0.bold })
    #expect(allSpans.contains { $0.fg == ScribePalette.markdownItalic })
  }

  @Test func backtickTripletFalseFence() {
    let lines = render("Here is ``` some text")
    #expect(!lines.isEmpty)
  }

  @Test func backtickTripletAtStartOfText() {
    let lines = render("```not a fence")
    #expect(!lines.isEmpty)
  }

  @Test func multipleOverlappingPatterns() {
    let lines = render("**bold** normal *italic* `code` **bold2** *italic2* `code2`")
    let allSpans = lines.flatMap(\.spans)
    #expect(allSpans.filter { $0.bold }.count >= 2)
    #expect(allSpans.filter { $0.fg == ScribePalette.markdownItalic }.count >= 2)
    #expect(allSpans.filter { $0.fg == ScribePalette.markdownCode }.count >= 2)
  }

  @Test func adjacentPatternsNoSpace() {
    let lines = render("**bold***italic*`code`")
    #expect(!lines.isEmpty)
  }

  @Test func emptyPatternContent() {
    let lines = render("**** **** * * `` ``")
    #expect(!lines.isEmpty)
  }

  @Test func literalAsterisksInCodeSpan() {
    let lines = render("`**not bold**` and real **bold**")
    let allSpans = lines.flatMap(\.spans)
    let codeSpans = allSpans.filter { $0.fg == ScribePalette.markdownCode }
    #expect(codeSpans.contains { $0.text.contains("**not bold**") })
    #expect(allSpans.contains { $0.bold && $0.text.contains("bold") })
  }

  @Test func boldAcrossMultipleTextNodes() {
    let chunks = ["**bo", "ld", "**"]
    let snapshots = renderIncremental(chunks: chunks)
    let oneShot = render("**bold**")
    #expect(snapshots.last! == oneShot)
  }

  @Test func emojiInBold() {
    let lines = render("**🔥 fire**")
    let allSpans = lines.flatMap(\.spans)
    #expect(allSpans.contains { $0.bold && $0.text.contains("🔥") })
  }

  @Test func emojiInLink() {
    let lines = render("[🚀 launch](https://example.com)")
    let allSpans = lines.flatMap(\.spans)
    #expect(allSpans.contains { $0.text.contains("🚀") })
  }

  @Test func wideUnicode() {
    let lines = render("**日本語** and *中文* and `한국어`")
    let allSpans = lines.flatMap(\.spans)
    #expect(allSpans.contains { $0.bold && $0.text.contains("日本語") })
    #expect(allSpans.contains { $0.fg == ScribePalette.markdownItalic && $0.text.contains("中文") })
    #expect(allSpans.contains { $0.fg == ScribePalette.markdownCode && $0.text.contains("한국어") })
  }

  @Test func zeroWidthJoiners() {
    let lines = render("👨‍👩‍👧‍👦 family emoji")
    #expect(!lines.isEmpty)
  }

  @Test func combiningCharacters() {
    let lines = render("**café** résumé naïve")
    #expect(!lines.isEmpty)
  }

  @Test func veryLongLine() {
    let long = String(repeating: "a", count: 10_000)
    let lines = render(long)
    #expect(!lines.isEmpty)
    #expect(plainLines(lines).joined().count >= 10_000)
  }

  @Test func veryLongLineWithPatterns() {
    var s = ""
    for i in 0..<500 {
      s += "**bold\(i)** *italic\(i)* `code\(i)` "
    }
    let lines = render(s)
    let allSpans = lines.flatMap(\.spans)
    #expect(allSpans.filter { $0.bold }.count >= 500)
  }

  @Test func veryLongCodeBlock() {
    var code = "```swift\n"
    for i in 0..<500 {
      code += "let x\(i) = \(i)\n"
    }
    code += "```"
    let lines = render(code)
    #expect(lines.count > 500)
  }

  @Test func manyConsecutiveBlankLines() {
    let md = String(repeating: "\n", count: 100)
    let lines = render(md)
    #expect(
      lines.allSatisfy { $0.spans.allSatisfy { $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } })
  }

  @Test func deeplyNestedInline() {
    let lines = render("**bold *italic `code` italic* bold**")
    #expect(!lines.isEmpty)
  }

  @Test func repeatedTripleBackticksInline() {
    let lines = render("a ``` b ``` c ``` d ``` e")
    #expect(!lines.isEmpty)
  }

  @Test func everythingAllAtOnce() {

    let md =
      """
      # Heading 1

      This is a paragraph with **bold**, *italic*, ~~strikethrough~~, `code`,
      a [link](https://example.com), and an ![image](img.png).

      ## Heading 2

      > A block quote with **bold** inside.

      - List item **one**
      - List item *two*
      - List item `three`

      1. Ordered one
      2. Ordered two

      """
      + "| Col A | Col B |\n| --- | --- |\n| a1 | b1 |\n| a2 | b2 |\n\n"
        + """
        ```swift
        func greet() {
            print("hello")
        }
        ```

        ---

        Final paragraph with <b>HTML</b>.
        """
    let lines = render(md)
    let p = plainLines(lines)
    #expect(p.contains { $0.hasPrefix("# ") })
    #expect(p.contains { $0.contains("bold") })
    #expect(p.contains { $0.contains("> ") })
    #expect(p.contains { $0.contains("- ") })
    #expect(p.contains { $0.contains("1. ") })
    #expect(p.contains { $0.contains("a1") || $0.contains("b1") })
    #expect(p.contains("```swift"))
    #expect(p.contains("---"))
  }

  @Test func streamingMatchesOneShot_everything() {
    let md = """
      # Title

      This has **bold** and *italic* and `code`.

      > Block quote with **bold**

      - item 1
      - item 2

      ```swift
      let x = 1
      ```
      """
    let chars = md.map(String.init)
    let snapshots = renderIncremental(chunks: chars)
    let oneShot = render(md)
    #expect(snapshots.last! == oneShot)
  }

  @Test func streamingMatchesOneShot_complexPatterns() {
    let md = "**a** *b* `c` **d** *e* `f` **g** *h* `i`"
    let chunks = md.map(String.init)
    let snapshots = renderIncremental(chunks: chunks)
    let oneShot = render(md)
    #expect(snapshots.last! == oneShot)
  }

  @Test func spanMergingPreservesText() {
    let md = "**bold** normal *italic* `code`"
    let lines1 = render(md)
    let lines2 = render(md)
    #expect(plainLines(lines1) == plainLines(lines2))
  }

  @Test func safetyNetDoesNotDoubleStyle() {
    let lines = render("plain **bold** plain")
    let allSpans = lines.flatMap(\.spans)
    let boldSpans = allSpans.filter { $0.bold && $0.text == "bold" }
    let boldTextTotal = boldSpans.map(\.text).joined()
    #expect(boldTextTotal == "bold")
  }

  @Test func baseStyleAppliedToPlainText() {
    let lines = render("plain text", baseFG: ScribePalette.cyan, baseBold: false)
    let plainSpans = lines.flatMap(\.spans).filter { $0.text.contains("plain") }
    #expect(plainSpans.allSatisfy { $0.fg == ScribePalette.cyan && !$0.bold })
  }

  @Test func baseBoldApplied() {
    let lines = render("bold base", baseFG: ScribePalette.cyan, baseBold: true)
    let plainSpans = lines.flatMap(\.spans).filter { $0.text.contains("bold base") }
    #expect(plainSpans.allSatisfy { $0.bold })
  }
}
