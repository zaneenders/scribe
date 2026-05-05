import Foundation
import ScribeCore
import Testing

@Suite
struct ScribeErrorTests {

  // MARK: - Configuration errors

  @Test func configurationErrorDescriptionIncludesReason() {
    let error = ScribeError.configuration(key: "api.baseUrl", reason: "Base URL must be non-empty.")
    #expect(error.errorDescription == "Base URL must be non-empty.")
  }

  @Test func configurationErrorWithoutKey() {
    let error = ScribeError.configuration(key: nil, reason: "Could not load configuration.")
    #expect(error.errorDescription == "Could not load configuration.")
  }

  // MARK: - API HTTP errors

  @Test func apiHTTPErrorWithDetailAndHint() {
    let error = ScribeError.apiHTTPError(statusCode: 404, detail: "not found", hint: " Check your URL.")
    #expect(error.errorDescription == "chat/completions returned HTTP 404 — not found. Check your URL.")
  }

  @Test func apiHTTPErrorWithoutDetail() {
    let error = ScribeError.apiHTTPError(statusCode: 500, detail: "", hint: nil)
    #expect(error.errorDescription == "chat/completions returned HTTP 500")
  }

  @Test func apiHTTPErrorWithoutHint() {
    let error = ScribeError.apiHTTPError(statusCode: 401, detail: "unauthorized", hint: nil)
    #expect(error.errorDescription == "chat/completions returned HTTP 401 — unauthorized")
  }

  // MARK: - Session errors

  @Test func sessionCorruptedDescription() {
    let error = ScribeError.sessionCorrupted(reason: "Missing system message.")
    #expect(error.errorDescription == "Missing system message.")
  }

  // MARK: - Resume errors

  @Test func resumeNotFoundDescription() {
    let error = ScribeError.resumeNotFound(specifier: "abc123")
    #expect(error.errorDescription == "No session matches \"abc123\". Try `scribe chat --sessions`.")
  }

  @Test func resumeAmbiguousDescription() {
    let error = ScribeError.resumeAmbiguous(specifier: "abc")
    #expect(error.errorDescription == "Ambiguous session prefix \"abc\"; use a longer id or a full path.")
  }

  // MARK: - Input errors

  @Test func invalidInputDescription() {
    let error = ScribeError.invalidInput(message: "Empty --resume value.")
    #expect(error.errorDescription == "Empty --resume value.")
  }

  // MARK: - Generic errors

  @Test func genericErrorDescription() {
    let error = ScribeError.generic("Something unexpected happened.")
    #expect(error.errorDescription == "Something unexpected happened.")
  }

  // MARK: - Sendable conformance

  @Test func scribeErrorIsSendable() {
    let error: ScribeError = .configuration(key: "k", reason: "r")
    let box: Sendable = error
    _ = box
  }

  // MARK: - Equatable-like distinguishability

  @Test func differentCasesAreNotEqual() {
    let a: ScribeError = .generic("a")
    let b: ScribeError = .invalidInput(message: "a")
    #expect(a != b)
  }

  @Test func sameCaseWithSameValuesAreEqual() {
    let a: ScribeError = .generic("x")
    let b: ScribeError = .generic("x")
    #expect(a == b)
  }

  @Test func sameCaseWithDifferentValuesAreNotEqual() {
    let a: ScribeError = .generic("x")
    let b: ScribeError = .generic("y")
    #expect(a != b)
  }
}
