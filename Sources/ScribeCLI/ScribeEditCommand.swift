import ArgumentParser
import ScribeCore

struct _ScribeEditCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "_edit",
    abstract: "Experimental scratch buffer editor.",
    discussion: "Underscore prefix = internal/testing surface."
  )

  func run() async throws {
    try await SlateEdit.runFullscreen()
  }
}
