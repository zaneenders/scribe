import Chroma
import Foundation
import ChromaTesting
import ScribeCodexAuth
import ScribeKit
import Testing

@testable import ScribeBlocks

@MainActor
struct CodexSignInTests {
  @Test func menuOffersSignInAndHidesItOnSuccess() async throws {
    let completion = AsyncStream<Void>.makeStream()
    let profile = ProfileSummary(name: "codex", model: "test-model", baseURL: "https://chatgpt.com/backend-api")
    let store = ScribeMacStore(
      startProfiling: false, codexIsSignedIn: false, loadCodexUsage: { throw SignInFailure() },
      codexSignIn: {
        for await _ in completion.stream { break }
        return [profile]
      })
    let renderer = HeadlessHost(size: Size(width: 1100, height: 760))
    defer { renderer.close() }
    renderer.content = ScribeMacRoot(store: store, theme: MacTheme(chromaTheme: .dark))
    #expect(!hasText("Sign in to Codex", in: renderer))
    store.toggleStatsMenu()
    #expect(hasText("Sign in to Codex", in: renderer))
    store.signInToCodex()
    store.signInToCodex()
    #expect(store.isSigningInToCodex)
    #expect(hasText("Cancel sign-in", in: renderer))
    completion.continuation.yield(())
    completion.continuation.finish()
    try await waitForSignIn(store)
    #expect(store.codexSignInStatus == "Codex signed in")
    #expect(store.profileCatalog == [profile])
    #expect(store.isSignedInToCodex)
    #expect(!hasText("Sign in to Codex", in: renderer))
  }

  @Test func signedInMenuShowsUsageAndRefreshesOnReopen() async throws {
    let usage = try JSONDecoder().decode(
      CodexUsage.self,
      from: Data(
        """
        {"rate_limit": {
          "primary_window": {"used_percent": 25, "reset_at": 1800000000, "limit_window_seconds": 18000},
          "secondary_window": {"used_percent": 60, "reset_at": 1800600000, "limit_window_seconds": 604800}
        }}
        """.utf8))
    let store = ScribeMacStore(startProfiling: false, codexIsSignedIn: true, loadCodexUsage: { usage })
    let renderer = HeadlessHost(size: Size(width: 1100, height: 760))
    defer { renderer.close() }
    renderer.content = ScribeMacRoot(store: store, theme: MacTheme(chromaTheme: .dark))
    store.toggleStatsMenu()
    try await waitForUsage(store)
    #expect(!hasText("Sign in to Codex", in: renderer))
    #expect(hasText("STATS", in: renderer))
    #expect(hasText("Codex usage", in: renderer))
    #expect(hasText("75% left", in: renderer))
    #expect(hasText("40% left", in: renderer))
    store.toggleStatsMenu()
    #expect(!hasText("75% left", in: renderer))
    store.toggleStatsMenu()
    #expect(store.isLoadingCodexUsage)
    try await waitForUsage(store)
  }

  @Test func usageFailureDoesNotOfferSignInUnlessCredentialsAreRejected() async throws {
    let store = ScribeMacStore(
      startProfiling: false, codexIsSignedIn: true,
      loadCodexUsage: {
        throw SignInFailure()
      })
    store.toggleStatsMenu()
    try await waitForUsage(store)
    #expect(store.isSignedInToCodex)
    #expect(store.codexUsageStatus == "Usage unavailable")

    let rejected = ScribeMacStore(
      startProfiling: false, codexIsSignedIn: true,
      loadCodexUsage: {
        throw CodexOAuthError.loginRequired
      })
    rejected.toggleStatsMenu()
    try await waitForUsage(rejected)
    #expect(!rejected.isSignedInToCodex)
    #expect(rejected.codexSignInStatus == "Please sign in again")
  }

  private func waitForUsage(_ store: ScribeMacStore) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while store.isLoadingCodexUsage {
      try #require(ContinuousClock.now < deadline, "Usage did not load")
      await Task.yield()
    }
  }

  @Test func failedSignInShowsUsefulErrorAndCanBeRetried() async throws {
    let store = ScribeMacStore(
      startProfiling: false, codexIsSignedIn: false, loadCodexUsage: { throw SignInFailure() },
      codexSignIn: {
        throw SignInFailure()
      })
    store.signInToCodex()
    try await waitForSignIn(store)
    #expect(store.lastError == "Could not open callback server")
    #expect(store.codexSignInStatus == nil)
    store.signInToCodex()
    #expect(store.lastError == nil)
    try await waitForSignIn(store)
    #expect(store.lastError == "Could not open callback server")
  }

  @Test func signInCanBeCancelled() async throws {
    let store = ScribeMacStore(
      startProfiling: false, codexIsSignedIn: false, loadCodexUsage: { throw SignInFailure() },
      codexSignIn: {
        try await Task.sleep(for: .seconds(300))
        return []
      })
    store.signInToCodex()
    store.cancelCodexSignIn()
    try await waitForSignIn(store)
    #expect(store.lastError == nil)
    #expect(store.codexSignInStatus == nil)
  }

  private func waitForSignIn(_ store: ScribeMacStore) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while store.isSigningInToCodex {
      try #require(ContinuousClock.now < deadline, "Sign-in did not complete")
      await Task.yield()
    }
  }

  private func hasText(_ text: String, in renderer: HeadlessHost) -> Bool {
    renderer.render().commands.contains {
      if case .text(_, let value, _, _) = $0 { return value == text }
      return false
    }
  }
}

private struct SignInFailure: LocalizedError {
  var errorDescription: String? { "Could not open callback server" }
}
