@testable import Scribe

func enableTestLogging(write_to_file: Bool = true) {
  enableLogging(
    file_path: "scribe.log", logLevel: .trace, tracing: false, write_to_file: write_to_file)
  clearLog("scribe.log")
}
