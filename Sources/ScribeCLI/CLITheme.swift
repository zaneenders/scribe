import ScribeCore
import SlateCore

public struct CLITheme: Sendable {

  public var markdown: MarkdownTheme

  public var background: TerminalRGB

  public var inputAreaBg: TerminalRGB

  public var userPrefix: TerminalRGB

  public var userBody: TerminalRGB

  public var scribePrefix: TerminalRGB

  public var sectionLabel: TerminalRGB

  public var emptyTurn: TerminalRGB

  public var toolRoundHeader: TerminalRGB

  public var toolNames: TerminalRGB

  public var toolInvocation: TerminalRGB

  public var toolArgSummary: TerminalRGB

  public var toolOutput: TerminalRGB

  public var skippedStreamLine: TerminalRGB

  public var errorFG: TerminalRGB

  public var warningFG: TerminalRGB

  public var interruptedFG: TerminalRGB

  public var reasoningBaseFG: TerminalRGB

  public var answerBaseFG: TerminalRGB

  public var inputText: TerminalRGB

  public var inputCursor: TerminalRGB

  public var inputGutter: TerminalRGB

  public var spinnerGlyph: TerminalRGB

  public var queuedPrefix: TerminalRGB

  public var queuedText: TerminalRGB

  public var queuedGutter: TerminalRGB

  public var bannerLabel: TerminalRGB

  public var bannerValue: TerminalRGB

  public var usageLabel: TerminalRGB

  public var usagePrompt: TerminalRGB

  public var usageCompletion: TerminalRGB

  public var usageReasoning: TerminalRGB

  public var usageCache: TerminalRGB

  public var usageRate: TerminalRGB

  public var usageTurnSum: TerminalRGB

  public var usageSessionSum: TerminalRGB

  public var usageMuted: TerminalRGB

  public var usageCtxPctNormal: TerminalRGB

  public var usageCtxPctWarn: TerminalRGB

  public var usageCtxPctDanger: TerminalRGB

  public func style(for section: AssistantStreamSection) -> (fg: TerminalRGB, bold: Bool) {
    switch section {
    case .reasoning: (reasoningBaseFG, false)
    case .answer: (answerBaseFG, false)
    }
  }

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
