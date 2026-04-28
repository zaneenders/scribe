import Foundation

struct AgentAPIError: Error, LocalizedError {
  var errorDescription: String?

  init(description: String) {
    self.errorDescription = description
  }
}
