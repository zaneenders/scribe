import Foundation
import OpenAPIAsyncHTTPClient
import OpenAPIRuntime

/// Factory for the generated client used to communicate with a local Scribe daemon.
public enum ScribeAPIClient {
  public static func make(serverURL: URL) -> Client {
    Client(serverURL: serverURL, transport: AsyncHTTPClientTransport())
  }
}
