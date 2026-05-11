import Foundation
import ScribeCore
import SlateCore
import Testing

@testable import ScribeCLI

// MARK: - MarkdownToSlateAdapter tests

@Suite
struct MarkdownToSlateAdapterTests {

  private let theme = MarkdownTheme.vibrant
  private let baseFG: TerminalRGB = ScribePalette.cyan
  private let baseBold = false

  // MARK: - Forward conversion: MarkdownLine → TLine

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

  // MARK: - Array conversion

  @Test func convertMultipleLines() {
    let lines = [
      MarkdownLine(spans: [MarkdownSpan(text: "one", kind: .plain)]),
      MarkdownLine(spans: [MarkdownSpan(text: "two", kind: .bold)]),
    ]
    let result = MarkdownToSlateAdapter.convert(lines, baseFG: baseFG, baseBold: baseBold, theme: theme)
    #expect(result.count == 2)
    #expect(result[1].spans[0].bold)
  }

  // MARK: - Reverse conversion: TLine → MarkdownLine

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

// MARK: - Reverse conversion completeness tests

@Suite
struct MarkdownToSlateReverseConversionTests {

    private let theme = MarkdownTheme.vibrant
    private let baseFG: TerminalRGB = ScribePalette.cyan
    private let baseBold = false

    @Test func reverseConvertItalic() {
        let span = StyledSpan(fg: theme.italic, bg: theme.background, bold: false, text: "italic")
        let result = MarkdownToSlateAdapter.convert(span, baseFG: baseFG, baseBold: false, theme: theme)
        #expect(result.kind == MarkdownSpanKind.italic)
    }

    @Test func reverseConvertCode() {
        let span = StyledSpan(fg: theme.code, bg: theme.background, bold: false, text: "code")
        let result = MarkdownToSlateAdapter.convert(span, baseFG: baseFG, baseBold: false, theme: theme)
        #expect(result.kind == MarkdownSpanKind.code)
    }

    @Test func reverseConvertHeadingPrefix() {
        let span = StyledSpan(fg: theme.headingPrefix, bg: theme.background, bold: false, text: "## ")
        let result = MarkdownToSlateAdapter.convert(span, baseFG: baseFG, baseBold: false, theme: theme)
        if case .headingPrefix = result.kind {
            // expected
        } else {
            #expect(Bool(false), "expected headingPrefix, got \(result.kind)")
        }
    }

    @Test func reverseConvertHeading() {
        let span = StyledSpan(fg: theme.heading, bg: theme.background, bold: true, text: "Title")
        let result = MarkdownToSlateAdapter.convert(span, baseFG: baseFG, baseBold: false, theme: theme)
        if case .heading = result.kind {
            // expected
        } else {
            #expect(Bool(false), "expected heading, got \(result.kind)")
        }
    }

    @Test func reverseConvertListMarker() {
        let span = StyledSpan(fg: theme.listMarker, bg: theme.background, bold: false, text: "- ")
        let result = MarkdownToSlateAdapter.convert(span, baseFG: baseFG, baseBold: false, theme: theme)
        #expect(result.kind == MarkdownSpanKind.listMarker)
    }

    @Test func reverseConvertBlockquote() {
        let span = StyledSpan(fg: theme.blockquote, bg: theme.background, bold: false, text: "> q")
        let result = MarkdownToSlateAdapter.convert(span, baseFG: baseFG, baseBold: false, theme: theme)
        #expect(result.kind == MarkdownSpanKind.blockquote)
    }

    @Test func reverseConvertLink() {
        let span = StyledSpan(fg: theme.link, bg: theme.background, bold: false, text: "click")
        let result = MarkdownToSlateAdapter.convert(span, baseFG: baseFG, baseBold: false, theme: theme)
        #expect(result.kind == MarkdownSpanKind.link)
    }

    @Test func reverseConvertCodeBlock() {
        let span = StyledSpan(fg: theme.codeBlock, bg: theme.background, bold: false, text: "code")
        let result = MarkdownToSlateAdapter.convert(span, baseFG: baseFG, baseBold: false, theme: theme)
        #expect(result.kind == MarkdownSpanKind.codeBlock)
    }

    @Test func reverseConvertThematicBreak() {
        let span = StyledSpan(fg: theme.hr, bg: theme.background, bold: false, text: "---")
        let result = MarkdownToSlateAdapter.convert(span, baseFG: baseFG, baseBold: false, theme: theme)
        #expect(result.kind == MarkdownSpanKind.thematicBreak)
    }

    @Test func reverseConvertMuted() {
        let span = StyledSpan(fg: theme.muted, bg: theme.background, bold: false, text: "muted")
        let result = MarkdownToSlateAdapter.convert(span, baseFG: baseFG, baseBold: false, theme: theme)
        #expect(result.kind == MarkdownSpanKind.muted)
    }

    @Test func reverseConvertUnknownFallsBackToPlain() {
        // A color that doesn't match any theme color → .plain
        let span = StyledSpan(fg: TerminalRGB(r: 255, g: 0, b: 255), bg: theme.background, bold: false, text: "unknown")
        let result = MarkdownToSlateAdapter.convert(span, baseFG: baseFG, baseBold: false, theme: theme)
        #expect(result.kind == MarkdownSpanKind.plain)
    }

    @Test func reverseConvertBoldBaseBoldPlainMatchesBase() {
        // When base is bold and the span matches base FG + bold → plain
        let span = StyledSpan(fg: baseFG, bg: theme.background, bold: true, text: "plain but bold")
        let result = MarkdownToSlateAdapter.convert(span, baseFG: baseFG, baseBold: true, theme: theme)
        #expect(result.kind == MarkdownSpanKind.plain)
    }

    @Test func reverseConvertTLineFullRoundTrip() {
        // Every kind round-trips through TLine → MarkdownLine → TLine
        let original: [MarkdownSpanKind] = [
            .plain, .bold, .italic, .code,
            .headingPrefix(level: 2), .heading(level: 1),
            .listMarker, .blockquote, .link, .codeBlock,
            .thematicBreak, .muted,
        ]
        let texts = [
            "plain", "bold", "italic", "code",
            "## ", "Title",
            "- ", "> q", "link", "code", "---", "muted",
        ]

        for (kind, text) in zip(original, texts) {
            let markdownLine = MarkdownLine(spans: [MarkdownSpan(text: text, kind: kind)])
            let tLine = MarkdownToSlateAdapter.convert(markdownLine, baseFG: baseFG, baseBold: baseBold, theme: theme)
            let back = MarkdownToSlateAdapter.convert(tLine, baseFG: baseFG, baseBold: baseBold, theme: theme)
            #expect(back.spans[0].text == text)
            // The inferred kind should match (or at minimum not be wrong)
            // For heading/headingPrefix the level may be lost (inferKind uses level:0),
            // so we only check that the base kind category matches.
            switch (kind, back.spans[0].kind) {
            case (.plain, .plain), (.bold, .bold), (.italic, .italic),
                 (.code, .code), (.listMarker, .listMarker),
                 (.blockquote, .blockquote), (.link, .link),
                 (.codeBlock, .codeBlock), (.thematicBreak, .thematicBreak),
                 (.muted, .muted):
                break // OK
            case (.headingPrefix, .headingPrefix), (.heading, .heading):
                break // OK
            default:
                #expect(Bool(false), "Round-trip mismatch: \(kind) → \(back.spans[0].kind)")
            }
        }
    }
}
