// MARK: - Semantic markdown output types (terminal-agnostic)

/// Semantic markdown rendering output — no terminal-specific types.
/// Mapped to terminal cells by a separate Slate-specific adapter.
public enum MarkdownSpan: Equatable, Sendable {
    /// Plain body text.
    case body(String)
    /// Bold body text.
    case bold(String)
    /// Italic body text.
    case italic(String)
    /// Inline code.
    case code(String)
    /// A code block line.
    case codeBlock(String)
    /// A heading line.
    case heading(String)
    /// A blockquote line.
    case blockquote(String)
    /// A list item marker.
    case listMarker(String)
    /// A thematic break.
    case thematicBreak
    /// A link (text + URL).
    case link(text: String, url: String)
}

/// A line of rendered markdown, composed of semantic spans.
public struct MarkdownLine: Equatable, Sendable {
    public var spans: [MarkdownSpan]

    public init(spans: [MarkdownSpan]) {
        self.spans = spans
    }
}

/// Semantic color roles — no RGB values, just semantic names.
public enum MarkdownColorRole: Sendable {
    case body
    case dim
    case accent
    case code
    case heading
    case blockquote
}

/// Semantic color theme — maps roles to named palette entries.
public struct MarkdownColorTheme: Sendable {
    public var body: MarkdownColorRole
    public var dim: MarkdownColorRole
    public var accent: MarkdownColorRole
    public var code: MarkdownColorRole
    public var heading: MarkdownColorRole
    public var blockquote: MarkdownColorRole

    public init(
        body: MarkdownColorRole = .body,
        dim: MarkdownColorRole = .dim,
        accent: MarkdownColorRole = .accent,
        code: MarkdownColorRole = .code,
        heading: MarkdownColorRole = .heading,
        blockquote: MarkdownColorRole = .blockquote
    ) {
        self.body = body
        self.dim = dim
        self.accent = accent
        self.code = code
        self.heading = heading
        self.blockquote = blockquote
    }

    public static let `default` = MarkdownColorTheme()
    public static let grayscale = MarkdownColorTheme(
        body: .dim,
        dim: .dim,
        accent: .dim,
        code: .dim,
        heading: .dim,
        blockquote: .dim
    )
}

// MARK: - Markdown renderer protocol

/// Protocol in ScribeCore for rendering markdown to semantic output.
/// Implementations are expected to be stateless and `Sendable`.
public protocol MarkdownRenderer: Sendable {
    /// Render a complete markdown document.
    func render(
        text: String,
        baseFG: MarkdownColorRole,
        baseBold: Bool,
        theme: MarkdownColorTheme
    ) -> [MarkdownLine]

    /// Render a streaming (in-progress) markdown document.
    /// Only the visible tail is rendered for performance.
    func renderStreaming(
        text: String,
        baseFG: MarkdownColorRole,
        baseBold: Bool,
        theme: MarkdownColorTheme
    ) -> [MarkdownLine]
}

// MARK: - Code block highlighter protocol

/// Highlights code inside fenced code blocks.
/// Returns semantic `MarkdownLine` values — no terminal-specific types.
public protocol MarkdownCodeBlockHighlighter: Sendable {
    /// Highlight raw code and return one styled line per logical source line.
    func highlight(code: String, language: String?) -> [MarkdownLine]
}

/// Default highlighter that returns all lines as `.codeBlock`.
public struct PlainMarkdownCodeBlockHighlighter: MarkdownCodeBlockHighlighter {
    public init() {}

    public func highlight(code: String, language: String?) -> [MarkdownLine] {
        code.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            MarkdownLine(spans: [.codeBlock(String(line))])
        }
    }
}
