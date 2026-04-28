import Foundation

@main
enum ScribeCLI {
  static func main() async {
    do {
      try await AgentSession.run()
    } catch let error as AgentAPIError {
      let msg = error.errorDescription ?? String(describing: error)
      print("\(msg)\n")
      exit(1)
    } catch {
      print("\(error)\n")
      exit(1)
    }
  }
}
