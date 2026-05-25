import Foundation
import Logging
import Synchronization
import SystemPackage
import Testing

@testable import ScribeCore

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

@Suite
struct ShellStressTests {

  @Test func loopedCancelsDoNotLeakFDsOrPegCPU() async throws {
    let iterations = 20
    let beforeFDs = Self.openFDCount()
    let beforeCPU = Self.cpuTime()

    for i in 0..<iterations {
      let task = Task {

        try await Shell.run(
          command:
            "i=0; while [ $i -lt 1000 ]; do echo line$i; i=$((i+1)); sleep 0.001; done",
          cwd: nil,
          workingDirectory: FilePath("/tmp"), logger: toolRunnerTestLogger)
      }
      try await Task.sleep(for: .milliseconds(50))
      task.cancel()

      let iterStart = ContinuousClock.now
      _ = try? await task.value
      let iterElapsed = iterStart.duration(to: .now)
      #expect(
        iterElapsed < .seconds(3),
        "iteration \(i) took \(iterElapsed) — drain should settle within 3s")
    }

    let afterCPU = Self.cpuTime()
    let afterFDs = Self.openFDCount()

    let cpuDelta = afterCPU - beforeCPU

    if beforeFDs > 0 && afterFDs > 0 {
      let maxAllowedGrowth = 8 * iterations + 20
      #expect(
        afterFDs - beforeFDs <= maxAllowedGrowth,
        "open FD count grew from \(beforeFDs) to \(afterFDs) (+\(afterFDs - beforeFDs)) over \(iterations) cancelled shells — bound \(maxAllowedGrowth)"
      )
    }

    let cpuBudgetPerShell = 1.0
    let totalCpuBudget = Double(iterations) * cpuBudgetPerShell
    #expect(
      cpuDelta < totalCpuBudget,
      "consumed \(String(format: "%.2fs", cpuDelta)) of CPU over \(iterations) cancelled shells (budget \(String(format: "%.2fs", totalCpuBudget))) — possible CPU spin"
    )
  }

  private static func cpuTime() -> Double {
    #if canImport(Darwin)
    let who: Int32 = RUSAGE_SELF
    #else
    let who = Int32(RUSAGE_SELF.rawValue)
    #endif
    var ru = rusage()
    _ = getrusage(who, &ru)
    let user = Double(ru.ru_utime.tv_sec) + Double(ru.ru_utime.tv_usec) / 1_000_000.0
    let system = Double(ru.ru_stime.tv_sec) + Double(ru.ru_stime.tv_usec) / 1_000_000.0
    return user + system
  }

  private static func openFDCount() -> Int {
    let candidates = ["/dev/fd", "/proc/self/fd"]
    for path in candidates {
      if let entries = try? FileManager.default.contentsOfDirectory(atPath: path) {
        return entries.count
      }
    }
    return -1
  }
}
