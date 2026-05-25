import Foundation
import ScribeCore
import SlateCore
import Testing

@testable import ScribeCLI


@Suite
struct MarkdownToSlateAdapterTests {

  private let theme = MarkdownTheme.vibrant
  private let baseFG: TerminalRGB = ScribePalette.cyan
  private let baseBold = false


  @Test func convertPlainSpan() {
    let line = MarkdownLine(spans: [MarkdownSpan(text: "hello", kind: .plain)])
    let result = MarkdownToSlateAdapter.convert(line, baseFG: baseFG, baseBold: baseBold, theme: theme)
    #expect(result.spans.count == 1)
    #expect(result.spans[0].text == "hello")
    #expect(result.spans[0].fg == baseFG)
    #expect(!result.spans[0].bold)
  }

  @Test func convertBoldSpan() {
    let line = MarkdownLine(spans: [MarkdownSpan(text: "bold text", kind: .bold)])
    let result = MarkdownToSlateAdapter.convert(line, baseFG: baseFG, baseBold: baseBold, theme: theme)
    #expect(result.spans[0].bold)
    #expect(result.spans[0].fg == theme.bold)
  }

  @Test func convertItalicSpan() {
    let line = MarkdownLine(spans: [MarkdownSpan(text: "italic text", kind: .italic)])
    let result = MarkdownToSlateAdapter.convert(line, baseFG: baseFG, baseBold: baseBold, theme: theme)
    #expect(result.spans[0].fg == theme.italic)
  }

  @Test func convertCodeSpan() {
    let line = MarkdownLine(spans: [MarkdownSpan(text: "code", kind: .code)])
    let result = MarkdownToSlateAdapter.convert(line, baseFG: baseFG, baseBold: baseBold, theme: theme)
    #expect(result.spans[0].fg == theme.code)
    #expect(!result.spans[0].bold)
  }

  @Test func convertHeadingPrefix() {
    let line = MarkdownLine(spans: [MarkdownSpan(text: "### ", kind: .headingPrefix(level: 3))])
    let result = MarkdownToSlateAdapter.convert(line, baseFG: baseFG, baseBold: baseBold, theme: theme)
    #expect(result.spans[0].fg == theme.headingPrefix)
    #expect(!result.spans[0].bold)
  }

  @Test func convertHeading() {
    let line = MarkdownLine(spans: [MarkdownSpan(text: "Title", kind: .heading(level: 1))])
    let result = MarkdownToSlateAdapter.convert(line, baseFG: baseFG, baseBold: baseBold, theme: theme)
    #expect(result.spans[0].fg == theme.heading)
    #expect(result.spans[0].bold)
  }

  @Test func convertListMarker() {
    let line = MarkdownLine(spans: [MarkdownSpan(text: "- ", kind: .listMarker)])
    let result = MarkdownToSlateAdapter.convert(line, baseFG: baseFG, baseBold: baseBold, theme: theme)
    #expect(result.spans[0].fg == theme.listMarker)
  }

  @Test func convertBlockquote() {
    let line = MarkdownLine(spans: [MarkdownSpan(text: "> quoted", kind: .blockquote)])
    let result = MarkdownToSlateAdapter.convert(line, baseFG: baseFG, baseBold: baseBold, theme: theme)
    #expect(result.spans[0].fg == theme.blockquote)
  }

  @Test func convertLink() {
    let line = MarkdownLine(spans: [MarkdownSpan(text: "click", kind: .link)])
    let result = MarkdownToSlateAdapter.convert(line, baseFG: baseFG, baseBold: baseBold, theme: theme)
    #expect(result.spans[0].fg == theme.link)
  }

  @Test func convertMuted() {
    let line = MarkdownLine(spans: [MarkdownSpan(text: "muted", kind: .muted)])
    let result = MarkdownToSlateAdapter.convert(line, baseFG: baseFG, baseBold: baseBold, theme: theme)
    #expect(result.spans[0].fg == theme.muted)
  }


  @Test func convertMultipleLines() {
    let lines = [
      MarkdownLine(spans: [MarkdownSpan(text: "one", kind: .plain)]),
      MarkdownLine(spans: [MarkdownSpan(text: "two", kind: .bold)]),
    ]
    let result = MarkdownToSlateAdapter.convert(lines, baseFG: baseFG, baseBold: baseBold, theme: theme)
    #expect(result.count == 2)
    #expect(result[1].spans[0].bold)
  }


  @Test func reverseConvertPlain() {
    let span = StyledSpan(fg: baseFG, bg: theme.background, bold: false, text: "plain")
    let result = MarkdownToSlateAdapter.convert(span, baseFG: baseFG, baseBold: false, theme: theme)
    #expect(result.kind == MarkdownSpanKind.plain)
    #expect(result.text == "plain")
  }

  @Test func reverseConvertBold() {
    let span = StyledSpan(fg: theme.bold, bg: theme.background, bold: true, text: "bold")
    let result = MarkdownToSlateAdapter.convert(span, baseFG: baseFG, baseBold: false, theme: theme)
    #expect(result.kind == MarkdownSpanKind.bold)
  }

  @Test func reverseConvertRoundTrip() {
    let original = MarkdownLine(spans: [
      MarkdownSpan(text: "Hello ", kind: MarkdownSpanKind.plain),
      MarkdownSpan(text: "world", kind: MarkdownSpanKind.bold),
    ])
    let slateLine = MarkdownToSlateAdapter.convert(original, baseFG: baseFG, baseBold: baseBold, theme: theme)
    let back = MarkdownToSlateAdapter.convert(slateLine, baseFG: baseFG, baseBold: baseBold, theme: theme)
    #expect(back.spans.count == 2)
    #expect(back.spans[0].text == "Hello ")
    #expect(back.spans[0].kind == MarkdownSpanKind.plain)
    #expect(back.spans[1].text == "world")
    #expect(back.spans[1].kind == MarkdownSpanKind.bold)
  }
}
