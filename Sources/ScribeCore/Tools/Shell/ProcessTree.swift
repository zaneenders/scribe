import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

package protocol ProcessTreeReader: Sendable {
  func children(of pid: pid_t) -> [pid_t]
}

package func collectProcessTree(
  rootPid: pid_t,
  reader: any ProcessTreeReader
) -> [pid_t] {
  var pids: [pid_t] = [rootPid]
  var i = 0
  while i < pids.count {
    let current = pids[i]
    for child in reader.children(of: current) where child > 2 {
      if !pids.contains(child) {
        pids.append(child)
      }
    }
    i += 1
  }
  return pids
}

#if os(Linux)

package struct ProcfsTreeReader: ProcessTreeReader {
  package init() {}
  package func children(of pid: pid_t) -> [pid_t] {
    let path = "/proc/\(pid)/task/\(pid)/children"
    guard let content = try? String(contentsOfFile: path, encoding: .utf8) else {
      return []
    }
    let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return [] }
    return trimmed.split(separator: " ").compactMap { pid_t($0) }
  }
}
#endif
