@testable import Scribe

func enableTestLogging() {
  enableLogging(
    file_path: "scribe.log", logLevel: .trace, tracing: false, write_to_file: true)
  clearLog("scribe.log")
}
