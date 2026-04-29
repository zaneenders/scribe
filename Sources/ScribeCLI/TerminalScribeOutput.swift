import Foundation
import ScribeCore
import ScribeTUI

/// Terminal ``ScribeAgentOutput`` built from ``ScribeTUI`` primitives; swap for another conforming type at the host if you add SwiftUI / headless routing.
///
/// Stateless; safe as ``Sendable`` because output goes through process-global handles only.
public struct TerminalScribeOutput: ScribeAgentOutput {
  public init() {}

  public func printConfigBanner(baseURL: String, model: String, cwd: String) {
    let labelGray = ANSI.grayDark
    let valueGray = ANSI.grayLight
    print(
      "\(labelGray)LLM:\(ANSI.reset) \(valueGray)\(baseURL)\(ANSI.reset)\n\(labelGray)Model:\(ANSI.reset) \(valueGray)\(model)\(ANSI.reset)\n\(labelGray)CWD:\(ANSI.reset) \(valueGray)\(cwd)\(ANSI.reset)\n"
    )
  }

  public func printUserPromptDecoration() {
    try? FileHandle.standardOutput.write(
      contentsOf: Data("\(ANSI.orange)you:\(ANSI.reset) ".utf8))
  }

  public func enterAssistantStreamSection(
    _ section: AssistantStreamSection,
    previous: AssistantStreamSection?
  ) throws {
    try FileHandle.standardOutput.write(contentsOf: Data(ANSI.reset.utf8))
    if previous != nil {
      try FileHandle.standardOutput.write(contentsOf: Data("\n".utf8))
    }
    try FileHandle.standardOutput.write(
      contentsOf: Data("\(ANSI.purple)scribe:\(ANSI.reset)\n".utf8))
    switch section {
    case .reasoning:
      try FileHandle.standardOutput.write(contentsOf: Data("\(ANSI.thinking)  ".utf8))
    case .answer:
      try FileHandle.standardOutput.write(contentsOf: Data(ANSI.cyan.utf8))
    }
  }

  public func appendAssistantStreamText(_ section: AssistantStreamSection, text: String) throws {
    _ = section
    try FileHandle.standardOutput.write(contentsOf: Data(text.utf8))
    try FileHandle.standardOutput.synchronize()
  }

  public func finalizeAssistantStreamIfNeeded(streamHadVisibleTokens: Bool) throws {
    guard streamHadVisibleTokens else { return }
    try FileHandle.standardOutput.write(contentsOf: Data("\(ANSI.reset)\n".utf8))
    try FileHandle.standardOutput.synchronize()
  }

  public func printEmptyAssistantTurn() throws {
    print(
      "\(ANSI.purple)scribe:\(ANSI.reset)\n\(ANSI.dim)(empty turn)\(ANSI.reset)"
    )
  }

  public func emitUsage(
    promptTokens: Int?,
    completionTokens: Int?,
    totalTokens: Int?
  ) throws {
    guard
      let line = UsageBanner.line(
        promptTokens: promptTokens,
        completionTokens: completionTokens,
        totalTokens: totalTokens
      )
    else { return }
    print(line)
  }

  public func printBlankLine() throws {
    print()
  }

  public func printToolRoundHeader(round: Int, toolNames: [String]) throws {
    print(
      "\(ANSI.yellow)\(ANSI.bold)tool round \(round)\(ANSI.reset) "
        + "\(ANSI.cyan)\(toolNames.joined(separator: ", "))\(ANSI.reset)"
    )
  }

  public func printToolInvocation(
    name: String,
    argumentSummary: String?,
    outputLines: [String]
  ) throws {
    let head =
      "\(ANSI.yellow)▶ \(name)\(ANSI.reset)"
      + (argumentSummary.map { " \(ANSI.dim)\($0)\(ANSI.reset)" } ?? "")
    print(head)
    for line in outputLines {
      print("  \(line)")
    }
  }

  public func printMaxToolRoundsExceeded(max: Int) throws {
    print("\(ANSI.yellow)Stopped: max tool rounds (\(max)) exceeded.\(ANSI.reset)\n")
  }

  public func printSkippedUnreadableStreamLine() throws {
    try FileHandle.standardError.write(
      contentsOf: Data(
        "\(ANSI.dim)(skipped one stream line: not valid completion JSON)\(ANSI.reset)\n".utf8
      ))
  }

  public func printHarnessRunError(_ error: Error) throws {
    print("\(ANSI.red)error: \(error)\(ANSI.reset)\n")
  }
}
