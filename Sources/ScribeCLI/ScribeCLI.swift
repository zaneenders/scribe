import ArgumentParser
import Foundation

@main struct ScribeCLI: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "scribe",
    abstract: "Scribe coding agent",
    discussion: "",
    version: "0.0.1",
    subcommands: [Chat.self],
    defaultSubcommand: Chat.self
  )
  func run() async throws {}
}
