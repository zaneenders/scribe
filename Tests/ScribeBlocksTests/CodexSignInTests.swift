import Chroma
import Foundation
import ChromaTesting
import ScribeKit
import Testing

@testable import ScribeBlocks

@MainActor
struct CodexSignInTests {
  @Test func headerOffersSignInAndUpdatesProfilesOnSuccess() async throws {
    let completion = AsyncStream<Void>.makeStream()
    let profile = ProfileSummary(name: "codex", model: "test-model", baseURL: "https://chatgpt.com/backend-api")
    let store = ScribeMacStore(startProfiling: false, codexSignIn: {
      for await _ in completion.stream { break }
      return [profile]
    })
    let renderer = HeadlessHost(size: Size(width: 1100, height: 760))
    defer { renderer.close() }
    renderer.content = ScribeMacRoot(store: store, theme: MacTheme(chromaTheme: .dark))
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
    #expect(hasText("Sign in to Codex", in: renderer))
  }

  @Test func failedSignInShowsUsefulErrorAndCanBeRetried() async throws {
    let store = ScribeMacStore(startProfiling: false, codexSignIn: {
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
    let store = ScribeMacStore(startProfiling: false, codexSignIn: {
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
