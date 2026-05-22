import ScribeCore
import SlateCore

/// All colors used by the Scribe CLI, in one place.
///
/// Create a custom instance to tweak the look without hunting through layout code.
/// The ``default`` theme is the vibrant Easter-pastel dark-mode palette.
public struct CLITheme: Sendable {
  /// Markdown styling (headings, bold, code, etc.).
  public var markdown: MarkdownTheme

  // MARK: - Backgrounds

  /// Main transcript / grid background.
  public var background: TerminalRGB
  /// Bottom input-strip background.
  public var inputAreaBg: TerminalRGB

  // MARK: - Transcript chrome

  /// "you:" prefix in transcript scrollback.
  public var userPrefix: TerminalRGB
  /// User message body text in transcript scrollback.
  public var userBody: TerminalRGB
  /// "scribe:" prefix before assistant sections.
  public var scribePrefix: TerminalRGB
  /// "· reasoning" / "· answer" sub-headers.
  public var sectionLabel: TerminalRGB
  /// "(empty turn)" placeholder.
  public var emptyTurn: TerminalRGB
  /// "tool round N" header.
  public var toolRoundHeader: TerminalRGB
  /// Tool names listed in the round header.
  public var toolNames: TerminalRGB
  /// "▶ toolname" invocation line.
  public var toolInvocation: TerminalRGB
  /// Tool argument summary text.
  public var toolArgSummary: TerminalRGB
  /// Indented tool output lines.
  public var toolOutput: TerminalRGB
  /// "(skipped one stream line…)" notice.
  public var skippedStreamLine: TerminalRGB
  /// Error messages.
  public var errorFG: TerminalRGB
  /// Inline warning notices.
  public var warningFG: TerminalRGB
  /// "(interrupted)" notice.
  public var interruptedFG: TerminalRGB
  /// Base text color for reasoning sections.
  public var reasoningBaseFG: TerminalRGB
  /// Base text color for answer sections.
  public var answerBaseFG: TerminalRGB

  // MARK: - Grid chrome (input area, spinner, banner)

  /// Input line text.
  public var inputText: TerminalRGB
  /// Input cursor ("▏").
  public var inputCursor: TerminalRGB
  /// Input area gutter on continuation rows.
  public var inputGutter: TerminalRGB
  /// Braille spinner glyph while waiting for the LLM.
  public var spinnerGlyph: TerminalRGB
  /// "queued:" prefix in the queued-tray strip.
  public var queuedPrefix: TerminalRGB
  /// Queued tray message text.
  public var queuedText: TerminalRGB
  /// Queued tray gutter on continuation rows.
  public var queuedGutter: TerminalRGB
  /// Banner label ("LLM:", "Model:", "CWD:").
  public var bannerLabel: TerminalRGB
  /// Banner value text.
  public var bannerValue: TerminalRGB

  // MARK: - Usage HUD

  /// Labels ("in", "out", "rate", "ctx", "reasoning", "cache", "turn Σ", "all Σ").
  public var usageLabel: TerminalRGB
  /// Prompt / input token count.
  public var usagePrompt: TerminalRGB
  /// Completion / output token count.
  public var usageCompletion: TerminalRGB
  /// Reasoning / chain-of-thought token count.
  public var usageReasoning: TerminalRGB
  /// Cached prompt token count.
  public var usageCache: TerminalRGB
  /// Streaming throughput rate.
  public var usageRate: TerminalRGB
  /// Sum for the current user turn.
  public var usageTurnSum: TerminalRGB
  /// Sum since session start.
  public var usageSessionSum: TerminalRGB
  /// Separator dots / muted values.
  public var usageMuted: TerminalRGB
  /// Context-window percentage when below the warning threshold.
  public var usageCtxPctNormal: TerminalRGB
  /// Context-window percentage at or above the warning threshold.
  public var usageCtxPctWarn: TerminalRGB
  /// Context-window percentage at or above the danger threshold.
  public var usageCtxPctDanger: TerminalRGB

  // MARK: - Derived helpers

  /// Foreground color and bold flag for a streaming section.
  public func style(for section: AssistantStreamSection) -> (fg: TerminalRGB, bold: Bool) {
    switch section {
    case .reasoning: (reasoningBaseFG, false)
    case .answer: (answerBaseFG, false)
    }
  }

  // MARK: - Built-in themes

  /// Vibrant Easter-pastel dark-mode theme.
  public static let `default` = CLITheme(
    markdown: .vibrant,
    background: ScribePalette.black,
    inputAreaBg: ScribePalette.inputAreaBg,
    userPrefix: ScribePalette.orange,
    userBody: ScribePalette.white,
    scribePrefix: ScribePalette.purple,
    sectionLabel: ScribePalette.gray,
    emptyTurn: ScribePalette.gray,
    toolRoundHeader: ScribePalette.yellow,
    toolNames: ScribePalette.cyan,
    toolInvocation: ScribePalette.yellow,
    toolArgSummary: ScribePalette.gray,
    toolOutput: ScribePalette.grayLight,
    skippedStreamLine: ScribePalette.gray,
    errorFG: ScribePalette.red,
    warningFG: ScribePalette.yellow,
    interruptedFG: ScribePalette.gray,
    reasoningBaseFG: ScribePalette.grayLight,
    answerBaseFG: ScribePalette.cyan,
    inputText: ScribePalette.white,
    inputCursor: ScribePalette.white,
    inputGutter: ScribePalette.gray,
    spinnerGlyph: ScribePalette.yellowBright,
    queuedPrefix: ScribePalette.orange,
    queuedText: ScribePalette.grayLight,
    queuedGutter: ScribePalette.gray,
    bannerLabel: ScribePalette.grayDark,
    bannerValue: ScribePalette.grayLight,
    usageLabel: ScribePalette.usageLabel,
    usagePrompt: ScribePalette.usagePrompt,
    usageCompletion: ScribePalette.usageCompletion,
    usageReasoning: ScribePalette.usageReasoning,
    usageCache: ScribePalette.usageCache,
    usageRate: ScribePalette.usageRate,
    usageTurnSum: ScribePalette.usageTurnSum,
    usageSessionSum: ScribePalette.usageSessionSum,
    usageMuted: ScribePalette.usageMuted,
    usageCtxPctNormal: ScribePalette.usageLabel,
    usageCtxPctWarn: ScribePalette.yellow,
    usageCtxPctDanger: ScribePalette.red
  )
}
