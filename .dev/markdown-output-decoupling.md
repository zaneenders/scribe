# Decouple `MarkdownRenderer` from Slate terminal types

## Problem

`MarkdownRenderer` (protocol in `ScribeCLI`) and `SwiftMarkdownRenderer` return
`[TLine]` where `TLine` is a SlateCore type containing `StyledSpan` values with
`TerminalRGB` colors and style flags. This means:

1. `ScribeCore` cannot define `MarkdownRenderer` — it would have to depend on
   `SlateCore`, which is a TUI library irrelevant to the core agent.

2. The markdown rendering tests (`MarkdownRendererTests` in `ScribeCoreTests`)
   depend on `SlateCore` types even though they only test markdown-to-semantic
   structure transformation.

3. If the terminal rendering layer ever changes (different color model,
   different style representation), the markdown renderer must change too.

4. The proposed `TranscriptController` (see `transcript-controller.md`) must
   take a `MarkdownRenderer` parameter — but if `MarkdownRenderer` returns
   Slate types, `TranscriptController` is tied to Slate.

## Current type chain

```
Markdown text
  → SwiftMarkdownRenderer.render(text:baseFG:baseBold:theme:)
    → [TLine]  (SlateCore type: [StyledSpan], TerminalRGB colors)
      → SlateChatRenderer consumes [TLine] for grid building
```

## Proposed: introduce a semantic output type in ScribeCore

```swift
// ScribeCore/MarkdownOutput.swift

/// Semantic markdown rendering output — no terminal-specific types.
/// Mapped to terminal cells by a separate Slate-specific adapter.
enum MarkdownSpan: Equatable, Sendable {
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
struct MarkdownLine: Equatable, Sendable {
    var spans: [MarkdownSpan]
}

/// Protocol in ScribeCore for rendering markdown to semantic output.
protocol MarkdownRenderer: Sendable {
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

/// Semantic color roles — no RGB values, just semantic names.
enum MarkdownColorRole: Sendable {
    case body
    case dim
    case accent
    case code
    case heading
    case blockquote
}

/// Semantic color theme — maps roles to named palette entries.
struct MarkdownColorTheme: Sendable {
    var body: MarkdownColorRole = .body
    var dim: MarkdownColorRole = .dim
    var accent: MarkdownColorRole = .accent
    var code: MarkdownColorRole = .code
    var heading: MarkdownColorRole = .heading
    var blockquote: MarkdownColorRole = .blockquote
    static let `default` = MarkdownColorTheme()
    static let grayscale = MarkdownColorTheme(/* all .dim */)
}
```

## Slate-specific adapter

```swift
// ScribeCLI/Markdown/MarkdownToSlateAdapter.swift

/// Maps semantic MarkdownSpan → SlateCore StyledSpan using CLITheme colors.
struct MarkdownToSlateAdapter {
    let theme: CLITheme

    func convert(_ lines: [MarkdownLine]) -> [TLine] {
        lines.map { line in
            TLine(spans: line.spans.map { convert($0) })
        }
    }

    func convert(_ span: MarkdownSpan) -> StyledSpan {
        switch span {
        case .body(let text):    return StyledSpan(fg: theme.markdown.body, text: text)
        case .bold(let text):    return StyledSpan(fg: theme.markdown.body, bold: true, text: text)
        case .italic(let text):  return StyledSpan(fg: theme.markdown.body, bold: false, text: text) // TODO: italic support
        case .code(let text):    return StyledSpan(fg: theme.markdown.code, text: text)
        case .codeBlock(let text): return StyledSpan(fg: theme.markdown.code, text: text)
        case .heading(let text): return StyledSpan(fg: theme.markdown.heading, bold: true, text: text)
        case .blockquote(let text): return StyledSpan(fg: theme.markdown.blockquote, text: text)
        case .listMarker(let text): return StyledSpan(fg: theme.markdown.body, bold: true, text: text)
        case .thematicBreak:     return StyledSpan(fg: theme.markdown.dim, text: "───")
        case .link(let text, _): return StyledSpan(fg: theme.markdown.accent, text: text)
        }
    }
}
```

## What moves where

| Type | Current location | New location |
|---|---|---|
| `MarkdownRenderer` protocol | `ScribeCLI/Markdown/` | `ScribeCore/` |
| `MarkdownTheme` (becomes `MarkdownColorTheme`) | `ScribeCLI/Markdown/` | `ScribeCore/` |
| `SwiftMarkdownRenderer` | `ScribeCLI/Markdown/` | `ScribeCore/` |
| `MarkdownLine`, `MarkdownSpan`, `MarkdownColorRole` | *(new)* | `ScribeCore/` |
| `MarkdownToSlateAdapter` | *(new)* | `ScribeCLI/Markdown/` |
| `CodeBlockHighlighter` | `ScribeCLI/Markdown/` | `ScribeCore/` (no Slate dependency) |

## Existing MarkdownRendererTests

`MarkdownRendererTests` in `ScribeCoreTests` currently imports `SlateCore` and
asserts on `TLine` / `StyledSpan` values. After the split:

- `MarkdownRendererTests` asserts on `[MarkdownLine]` / `[MarkdownSpan]` (no Slate dependency).
- **New:** `MarkdownToSlateAdapterTests` in `ScribeCLITests` asserts on the `StyledSpan` mapping.

## Benefits

1. **ScribeCore stays terminal-agnostic** — the markdown renderer is a pure
   text→semantic-structure transformation, testable without any TUI library.

2. **TranscriptController can live in ScribeCLI** — it takes a `MarkdownRenderer`
   from `ScribeCore` (no Slate dependency in its signature), and a separate
   `MarkdownToSlateAdapter` converts the output to `[TLine]` for the Slate grid.

3. **Easier to swap renderers** — adding an alternative markdown renderer (e.g.,
   `cmark`-based) only requires implementing `MarkdownRenderer` → `[MarkdownLine]`;
   the Slate mapping stays the same.

4. **Terminal color changes are isolated** — if `CLITheme` changes its RGB palette,
   only `MarkdownToSlateAdapter` is affected; the markdown parser is untouched.

## Source changes

| File | Change |
|---|---|
| **New:** `ScribeCore/MarkdownOutput.swift` | `MarkdownLine`, `MarkdownSpan`, `MarkdownColorRole`, `MarkdownColorTheme` |
| **Modify:** `ScribeCore/` move `MarkdownRenderer` protocol | Move from `ScribeCLI/` to `ScribeCore/` |
| **Modify:** `ScribeCore/` move `SwiftMarkdownRenderer` | Move from `ScribeCLI/`; change return type |
| **New:** `ScribeCLI/Markdown/MarkdownToSlateAdapter.swift` | Slate-specific mapping |
| **Modify:** `ScribeCLI/Markdown/MarkdownTheme.swift` | Remove (replaced by `MarkdownColorTheme` in Core) |
| **Modify:** `SlateChatHost.swift` | Use `MarkdownToSlateAdapter` after `MarkdownRenderer` |
| **Modify:** `Tests/ScribeCoreTests/MarkdownRendererTests.swift` | Assert on `MarkdownLine`, not `TLine` |
| **New:** `Tests/ScribeCLITests/MarkdownToSlateAdapterTests.swift` | Adapter mapping tests |

## Implementation summary (completed)

### New files created
- **`ScribeCore/MarkdownOutput.swift`** — semantic types (`MarkdownSpan`, `MarkdownLine`, `MarkdownColorRole`, `MarkdownColorTheme`), the new `MarkdownRenderer` protocol (returning `[MarkdownLine]` instead of `[TLine]`), and `MarkdownCodeBlockHighlighter` protocol
- **`ScribeCore/SwiftMarkdownRenderer.swift`** — moved from `ScribeCLI`; now produces `MarkdownLine`/`MarkdownSpan` instead of `TLine`/`StyledSpan`; uses `MarkdownWalker` with `SpanContext` + `InlineContext` to emit correct semantic spans
- **`ScribeCLI/Markdown/MarkdownToSlateAdapter.swift`** — maps semantic spans → Slate `StyledSpan` using `MarkdownTheme` RGB palette; takes `bodyFG`/`bodyBold` for stream-section base styling

### Files removed
- `ScribeCLI/Markdown/MarkdownRenderer.swift` — old protocol (replaced by `MarkdownRenderer` in `ScribeCore`)
- `ScribeCLI/Markdown/SwiftMarkdownRenderer.swift` — moved to `ScribeCore`
- `ScribeCLI/Markdown/CodeBlockHighlighter.swift` — replaced by `MarkdownCodeBlockHighlighter` in `ScribeCore`

### Files modified
- **`Package.swift`** — added `Markdown` dependency to `ScribeCore`, removed from `ScribeCLI` and `ScribeCoreTests`
- **`SlateChatHost.swift`** — uses adapter pattern: `renderer` → `[MarkdownLine]` → `MarkdownToSlateAdapter.convert()` → `[TLine]`
- **`TranscriptReplay.swift`** — same adapter pattern for message replay
- **`MarkdownRendererTests.swift`** — rewritten to assert on `MarkdownLine`/`MarkdownSpan`; zero `SlateCore` imports in the semantic tests (one integration test still uses `TLine` via `@testable import ScribeCLI`)
- **`MarkdownTheme.swift`** — retained in `ScribeCLI` as the RGB palette consumed by the adapter (differs from `MarkdownColorTheme` which only carries semantic roles)

### Key outcomes
1. **`ScribeCore` is terminal-agnostic** — zero `import SlateCore` in the ScribeCore target
2. **`MarkdownRendererTests` decoupled from Slate** — 79 of 80 tests use only semantic types; one integration test (`debugSinkColors`) exercises the adapter path end-to-end
3. **All 293 tests pass** across 21 suites
4. **Terminal color changes are isolated** — if `CLITheme`/`MarkdownTheme` changes its RGB palette, only `MarkdownToSlateAdapter` is affected; the markdown parser in `ScribeCore` is untouched
