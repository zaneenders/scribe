import Foundation
import Testing

@testable import ScribeKit

/// The shared contract scenarios, run against the fake service.
@Suite
struct FakeServiceContractTests {

  @Test func capabilitiesListCreateOpenRoundTrip() async throws {
    try await ScribeServiceContractScenarios.capabilitiesListCreateOpenRoundTrip(
      FakeServiceFixture())
  }

  @Test func submitStreamsExactlyOneTerminalEventAndPersists() async throws {
    try await ScribeServiceContractScenarios.submitStreamsExactlyOneTerminalEventAndPersists(
      FakeServiceFixture())
  }

  @Test func overlappingSubmitForOneSessionIsRejected() async throws {
    try await ScribeServiceContractScenarios.overlappingSubmitForOneSessionIsRejected(
      FakeServiceFixture())
  }

  @Test func differentSessionsSubmitConcurrently() async throws {
    try await ScribeServiceContractScenarios.differentSessionsSubmitConcurrently(
      FakeServiceFixture())
  }

  @Test func interruptEndsActiveTurnAndIsIdempotent() async throws {
    try await ScribeServiceContractScenarios.interruptEndsActiveTurnAndIsIdempotent(
      FakeServiceFixture())
  }

  @Test func renameClearAndPinUpdateSummaries() async throws {
    try await ScribeServiceContractScenarios.renameClearAndPinUpdateSummaries(
      FakeServiceFixture())
  }

  @Test func reconfigureSwitchesProfileAndModel() async throws {
    try await ScribeServiceContractScenarios.reconfigureSwitchesProfileAndModel(
      FakeServiceFixture())
  }

  @Test func forkCreatesNewIdentityKeepingPrefix() async throws {
    try await ScribeServiceContractScenarios.forkCreatesNewIdentityKeepingPrefix(
      FakeServiceFixture())
  }

  @Test func summarizeSplicesRangeIntoNewIdentity() async throws {
    try await ScribeServiceContractScenarios.summarizeSplicesRangeIntoNewIdentity(
      FakeServiceFixture())
  }
}

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
