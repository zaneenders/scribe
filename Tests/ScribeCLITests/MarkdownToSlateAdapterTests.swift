import ScribeCore
import Testing

@testable import ScribeCLI

// MARK: - MarkdownToSlateAdapter tests

/// Tests that each `MarkdownSpan` variant maps to the correct `StyledSpan`
/// with the expected color, bold flag, and text.
@Suite
struct MarkdownToSlateAdapterTests {

    // MARK: - Single span conversions

    @Test func bodySpan_usesBodyFGAndBodyBold() {
        let adapter = MarkdownToSlateAdapter(
            theme: .vibrant, bodyFG: ScribePalette.cyan, bodyBold: false)

        let result = adapter.convert(MarkdownSpan.body("hello"))

        #expect(result.text == "hello")
        #expect(result.fg == ScribePalette.cyan)
        #expect(result.bold == false)
        #expect(result.bg == MarkdownTheme.vibrant.background)
    }

    @Test func bodySpan_withBodyBold() {
        let adapter = MarkdownToSlateAdapter(
            theme: .vibrant, bodyFG: ScribePalette.cyan, bodyBold: true)

        let result = adapter.convert(MarkdownSpan.body("hello"))

        #expect(result.text == "hello")
        #expect(result.fg == ScribePalette.cyan)
        #expect(result.bold == true)
    }

    @Test func boldSpan() {
        let adapter = MarkdownToSlateAdapter(
            theme: .vibrant, bodyFG: ScribePalette.cyan, bodyBold: false)

        let result = adapter.convert(MarkdownSpan.bold("bold text"))

        #expect(result.text == "bold text")
        #expect(result.fg == MarkdownTheme.vibrant.bold)
        #expect(result.bold == true)
    }

    @Test func italicSpan() {
        let adapter = MarkdownToSlateAdapter(
            theme: .vibrant, bodyFG: ScribePalette.cyan, bodyBold: false)

        let result = adapter.convert(MarkdownSpan.italic("italic text"))

        #expect(result.text == "italic text")
        #expect(result.fg == MarkdownTheme.vibrant.italic)
        #expect(result.bold == false)
    }

    @Test func codeSpan() {
        let adapter = MarkdownToSlateAdapter(
            theme: .vibrant, bodyFG: ScribePalette.cyan, bodyBold: false)

        let result = adapter.convert(MarkdownSpan.code("let x = 1"))

        #expect(result.text == "let x = 1")
        #expect(result.fg == MarkdownTheme.vibrant.code)
        #expect(result.bold == false)
    }

    @Test func codeBlockSpan() {
        let adapter = MarkdownToSlateAdapter(
            theme: .vibrant, bodyFG: ScribePalette.cyan, bodyBold: false)

        let result = adapter.convert(MarkdownSpan.codeBlock("print(\"hi\")"))

        #expect(result.text == "print(\"hi\")")
        #expect(result.fg == MarkdownTheme.vibrant.codeBlock)
        #expect(result.bold == false)
    }

    @Test func headingSpan() {
        let adapter = MarkdownToSlateAdapter(
            theme: .vibrant, bodyFG: ScribePalette.cyan, bodyBold: false)

        let result = adapter.convert(MarkdownSpan.heading("My Heading"))

        #expect(result.text == "My Heading")
        #expect(result.fg == MarkdownTheme.vibrant.heading)
        #expect(result.bold == true)
    }

    @Test func blockquoteSpan() {
        let adapter = MarkdownToSlateAdapter(
            theme: .vibrant, bodyFG: ScribePalette.cyan, bodyBold: false)

        let result = adapter.convert(MarkdownSpan.blockquote("quoted"))

        #expect(result.text == "quoted")
        #expect(result.fg == MarkdownTheme.vibrant.blockquote)
        #expect(result.bold == false)
    }

    @Test func listMarkerSpan() {
        let adapter = MarkdownToSlateAdapter(
            theme: .vibrant, bodyFG: ScribePalette.cyan, bodyBold: false)

        let result = adapter.convert(MarkdownSpan.listMarker("- "))

        #expect(result.text == "- ")
        #expect(result.fg == MarkdownTheme.vibrant.listMarker)
        #expect(result.bold == false)
    }

    @Test func thematicBreakSpan() {
        let adapter = MarkdownToSlateAdapter(
            theme: .vibrant, bodyFG: ScribePalette.cyan, bodyBold: false)

        let result = adapter.convert(MarkdownSpan.thematicBreak)

        #expect(result.text == "---")
        #expect(result.fg == MarkdownTheme.vibrant.hr)
        #expect(result.bold == false)
    }

    @Test func linkSpan() {
        let adapter = MarkdownToSlateAdapter(
            theme: .vibrant, bodyFG: ScribePalette.cyan, bodyBold: false)

        let result = adapter.convert(
            MarkdownSpan.link(text: "Click", url: "https://example.com"))

        #expect(result.text == "Click")
        #expect(result.fg == MarkdownTheme.vibrant.link)
        #expect(result.bold == false)
    }

    @Test func strikethroughSpan() {
        let adapter = MarkdownToSlateAdapter(
            theme: .vibrant, bodyFG: ScribePalette.cyan, bodyBold: false)

        let result = adapter.convert(MarkdownSpan.strikethrough("deleted"))

        #expect(result.text == "deleted")
        #expect(result.fg == MarkdownTheme.vibrant.muted)
        #expect(result.bold == false)
    }

    // MARK: - Line conversion

    @Test func convertLine_preservesSpanOrder() {
        let adapter = MarkdownToSlateAdapter(
            theme: .vibrant, bodyFG: ScribePalette.cyan, bodyBold: false)
        let line = MarkdownLine(spans: [
            .body("plain "),
            .bold("bold "),
            .code("code"),
        ])

        let result = adapter.convert([line])

        #expect(result.count == 1)
        #expect(result[0].spans.count == 3)
        #expect(result[0].spans[0].text == "plain ")
        #expect(result[0].spans[0].fg == ScribePalette.cyan)
        #expect(result[0].spans[1].text == "bold ")
        #expect(result[0].spans[1].bold == true)
        #expect(result[0].spans[2].text == "code")
        #expect(result[0].spans[2].fg == MarkdownTheme.vibrant.code)
    }

    @Test func convertLines_multipleLines() {
        let adapter = MarkdownToSlateAdapter(
            theme: .vibrant, bodyFG: ScribePalette.cyan, bodyBold: false)
        let lines: [MarkdownLine] = [
            MarkdownLine(spans: [.body("line 1")]),
            MarkdownLine(spans: [.body("line 2")]),
        ]

        let result = adapter.convert(lines)

        #expect(result.count == 2)
        #expect(result[0].spans.first?.text == "line 1")
        #expect(result[1].spans.first?.text == "line 2")
    }

    // MARK: - Grayscale theme

    @Test func grayscaleTheme_allSpansUseGrayscaleColors() {
        let adapter = MarkdownToSlateAdapter(
            theme: .grayscale, bodyFG: ScribePalette.grayLight, bodyBold: false)

        let spans: [MarkdownSpan] = [
            .body("body"),
            .bold("bold"),
            .italic("italic"),
            .code("code"),
            .codeBlock("codeblock"),
            .heading("heading"),
            .blockquote("blockquote"),
            .listMarker("- "),
            .thematicBreak,
            .link(text: "link", url: ""),
            .strikethrough("strike"),
        ]

        for span in spans {
            let result = adapter.convert(span)
            // All grayscale colors are dim — just verify they're not vibrant
            #expect(result.fg != MarkdownTheme.vibrant.bold)
            #expect(result.fg != MarkdownTheme.vibrant.heading)
        }
    }

    // MARK: - Background propagation

    @Test func allSpansUseThemeBackground() {
        let adapter = MarkdownToSlateAdapter(
            theme: .vibrant, bodyFG: ScribePalette.cyan, bodyBold: false)

        let spans: [MarkdownSpan] = [
            .body("a"), .bold("b"), .italic("c"), .code("d"),
            .codeBlock("e"), .heading("f"), .blockquote("g"),
            .listMarker("h"), .thematicBreak, .link(text: "i", url: ""),
            .strikethrough("j"),
        ]

        for span in spans {
            let result = adapter.convert(span)
            #expect(result.bg == MarkdownTheme.vibrant.background)
        }
    }
}
