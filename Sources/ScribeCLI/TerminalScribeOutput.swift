import Foundation
import ScribeCore
import SlateCore

/// Terminal ``ScribeAgentOutput`` that prints Slate-style truecolor CSI (``CSI``, ``TerminalRGB`` / ``ScribePalette``); swap for another conforming sink at alternate hosts.
///
/// Stateless; safe as ``Sendable`` because output goes through process-global handles only.
public struct TerminalScribeOutput: ScribeAgentOutput {
  public init() {}

  public func printConfigBanner(baseURL: String, model: String, cwd: String) {
    let labelGray = CSI.sgrForeground(ScribePalette.grayDark)
    let valueGray = CSI.sgrForeground(ScribePalette.grayLight)
    let x = CSI.sgr0
    print(
      "\(labelGray)LLM:\(x) \(valueGray)\(baseURL)\(x)\n\(labelGray)Model:\(x) \(valueGray)\(model)\(x)\n\(labelGray)CWD:\(x) \(valueGray)\(cwd)\(x)\n"
    )
  }

  public func printUserPromptDecoration() {
    try? FileHandle.standardOutput.write(
      contentsOf: Data("\(CSI.sgrForeground(ScribePalette.orange))you:\(CSI.sgr0) ".utf8))
  }

  public func enterAssistantStreamSection(
    _ section: AssistantStreamSection,
    previous: AssistantStreamSection?
  ) throws {
    try FileHandle.standardOutput.write(contentsOf: Data(CSI.sgr0.utf8))
    if previous != nil {
      try FileHandle.standardOutput.write(contentsOf: Data("\n".utf8))
    }
    try FileHandle.standardOutput.write(
      contentsOf: Data("\(CSI.sgrForeground(ScribePalette.purple))scribe:\(CSI.sgr0)\n".utf8))
    switch section {
    case .reasoning:
      try FileHandle.standardOutput.write(
        contentsOf: Data("\(CSI.sgrBoldForeground(ScribePalette.thinking))  ".utf8))
    case .answer:
      try FileHandle.standardOutput.write(
        contentsOf: Data(CSI.sgrForeground(ScribePalette.cyan).utf8))
    }
  }

  public func appendAssistantStreamText(_ section: AssistantStreamSection, text: String) throws {
    _ = section
    try FileHandle.standardOutput.write(contentsOf: Data(text.utf8))
    try FileHandle.standardOutput.synchronize()
  }

  public func finalizeAssistantStreamIfNeeded(streamHadVisibleTokens: Bool) throws {
    guard streamHadVisibleTokens else { return }
    try FileHandle.standardOutput.write(contentsOf: Data("\(CSI.sgr0)\n".utf8))
    try FileHandle.standardOutput.synchronize()
  }

  public func printEmptyAssistantTurn() throws {
    let x = CSI.sgr0
    print(
      "\(CSI.sgrForeground(ScribePalette.purple))scribe:\(x)\n\(CSI.sgrFaint)(empty turn)\(x)"
    )
  }

  public func emitUsage(
    promptTokens: Int?,
    completionTokens: Int?,
    totalTokens: Int?,
    outputTokensPerSecond: Double?
  ) throws {
    guard
      let line = UsageBanner.line(
        promptTokens: promptTokens,
        completionTokens: completionTokens,
        totalTokens: totalTokens,
        outputTokensPerSecond: outputTokensPerSecond
      )
    else { return }
    print(line)
  }

  public func printBlankLine() throws {
    print()
  }

  public func printToolRoundHeader(round: Int, toolNames: [String]) throws {
    let y = CSI.sgrForeground(ScribePalette.yellow)
    let b = CSI.sgrBold
    let x = CSI.sgr0
    print(
      "\(y)\(b)tool round \(round)\(x) "
        + "\(CSI.sgrForeground(ScribePalette.cyan))\(toolNames.joined(separator: ", "))\(x)"
    )
  }

  public func printToolInvocation(
    name: String,
    argumentSummary: String?,
    outputLines: [String]
  ) throws {
    let x = CSI.sgrFaint
    let z = CSI.sgr0
    let head =
      "\(CSI.sgrForeground(ScribePalette.yellow))▶ \(name)\(z)"
      + (argumentSummary.map { " \(x)\($0)\(z)" } ?? "")
    print(head)
    for line in outputLines {
      print("  \(line)")
    }
  }

  public func printMaxToolRoundsExceeded(max: Int) throws {
    print("\(CSI.sgrForeground(ScribePalette.yellow))Stopped: max tool rounds (\(max)) exceeded.\(CSI.sgr0)\n")
  }

  public func printSkippedUnreadableStreamLine() throws {
    try FileHandle.standardError.write(
      contentsOf: Data(
        "\(CSI.sgrFaint)(skipped one stream line: not valid completion JSON)\(CSI.sgr0)\n".utf8
      ))
  }

  public func printHarnessRunError(_ error: Error) throws {
    print("\(CSI.sgrForeground(ScribePalette.red))error: \(error)\(CSI.sgr0)\n")
  }

  public func printTurnInterrupted() throws {
    print("\(CSI.sgrFaint)(interrupted)\(CSI.sgr0)\n")
  }

  public func markModelTurnRunning(_ running: Bool) throws {
    _ = running
  }
}
