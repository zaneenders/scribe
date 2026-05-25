import Foundation
import Logging
import SystemPackage

public protocol ToolExecutor: Sendable {
  func execute(
    _ invocation: ToolInvocation,
    workingDirectory: FilePath,
    logger: Logger,
    abort: any AbortObserver
  ) async throws -> ToolResult
}
