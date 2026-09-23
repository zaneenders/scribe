import Foundation
import Testing

@testable import ScribeKit

/// The same shared contract scenarios, run against the local service with a
/// scripted agent runtime and a temporary home.
@Suite
struct LocalServiceContractTests {

  @Test func capabilitiesListCreateOpenRoundTrip() async throws {
    try await withLocalServiceFixture { fixture in
      try await ScribeServiceContractScenarios.capabilitiesListCreateOpenRoundTrip(fixture)
    }
  }

  @Test func submitStreamsExactlyOneTerminalEventAndPersists() async throws {
    try await withLocalServiceFixture { fixture in
      try await ScribeServiceContractScenarios.submitStreamsExactlyOneTerminalEventAndPersists(
        fixture)
    }
  }

  @Test func overlappingSubmitForOneSessionIsRejected() async throws {
    try await withLocalServiceFixture { fixture in
      try await ScribeServiceContractScenarios.overlappingSubmitForOneSessionIsRejected(fixture)
    }
  }

  @Test func differentSessionsSubmitConcurrently() async throws {
    try await withLocalServiceFixture { fixture in
      try await ScribeServiceContractScenarios.differentSessionsSubmitConcurrently(fixture)
    }
  }

  @Test func interruptEndsActiveTurnAndIsIdempotent() async throws {
    try await withLocalServiceFixture { fixture in
      try await ScribeServiceContractScenarios.interruptEndsActiveTurnAndIsIdempotent(fixture)
    }
  }

  @Test func renameClearAndPinUpdateSummaries() async throws {
    try await withLocalServiceFixture { fixture in
      try await ScribeServiceContractScenarios.renameClearAndPinUpdateSummaries(fixture)
    }
  }

  @Test func reconfigureSwitchesProfileAndModel() async throws {
    try await withLocalServiceFixture { fixture in
      try await ScribeServiceContractScenarios.reconfigureSwitchesProfileAndModel(fixture)
    }
  }

  @Test func forkCreatesNewIdentityKeepingPrefix() async throws {
    try await withLocalServiceFixture { fixture in
      try await ScribeServiceContractScenarios.forkCreatesNewIdentityKeepingPrefix(fixture)
    }
  }

  @Test func summarizeSplicesRangeIntoNewIdentity() async throws {
    try await withLocalServiceFixture { fixture in
      try await ScribeServiceContractScenarios.summarizeSplicesRangeIntoNewIdentity(fixture)
    }
  }
}
