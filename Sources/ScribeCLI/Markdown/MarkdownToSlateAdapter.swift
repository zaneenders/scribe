import ScribeCore
import SlateCore

/// Maps semantic `MarkdownSpan` → SlateCore `StyledSpan` using `MarkdownTheme` colors.
public struct MarkdownToSlateAdapter {
    public let theme: MarkdownTheme
    /// Foreground color for `.body` spans (typically stream section color, e.g. cyan or grayLight).
    public let bodyFG: TerminalRGB
    /// Bold flag for `.body` spans (typically from stream section).
    public let bodyBold: Bool

    public init(theme: MarkdownTheme, bodyFG: TerminalRGB, bodyBold: Bool = false) {
        self.theme = theme
        self.bodyFG = bodyFG
        self.bodyBold = bodyBold
    }

    public func convert(_ lines: [MarkdownLine]) -> [TLine] {
        lines.map { line in
            TLine(spans: line.spans.map { convert($0) })
        }
    }

    public func convert(_ span: MarkdownSpan) -> StyledSpan {
        let bg = theme.background
        switch span {
        case .body(let text):
            return StyledSpan(fg: bodyFG, bg: bg, bold: bodyBold, text: text)
        case .bold(let text):
            return StyledSpan(fg: theme.bold, bg: bg, bold: true, text: text)
        case .italic(let text):
            return StyledSpan(fg: theme.italic, bg: bg, bold: false, text: text)
        case .code(let text):
            return StyledSpan(fg: theme.code, bg: bg, bold: false, text: text)
        case .codeBlock(let text):
            return StyledSpan(fg: theme.codeBlock, bg: bg, bold: false, text: text)
        case .heading(let text):
            return StyledSpan(fg: theme.heading, bg: bg, bold: true, text: text)
        case .blockquote(let text):
            return StyledSpan(fg: theme.blockquote, bg: bg, bold: false, text: text)
        case .listMarker(let text):
            return StyledSpan(fg: theme.listMarker, bg: bg, bold: false, text: text)
        case .thematicBreak:
            return StyledSpan(fg: theme.hr, bg: bg, bold: false, text: "---")
        case .link(let text, _):
            return StyledSpan(fg: theme.link, bg: bg, bold: false, text: text)
        }
    }
}
