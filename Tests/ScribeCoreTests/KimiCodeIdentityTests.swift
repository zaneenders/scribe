import Foundation
import Testing

@testable import ScribeCore

@Suite
struct KimiCodeIdentityTests {

    // MARK: - requestHeaders

    @Test("requestHeaders includes all required fields")
    func requestHeadersIncludesAllRequiredFields() {
        let headers = KimiCodeIdentity.requestHeaders(version: "2.0")

        #expect(headers["User-Agent"] == "kimi-code-cli/2.0")
        #expect(headers["X-Msh-Platform"] == "kimi_code_cli")
        #expect(headers["X-Msh-Version"] == "2.0")
        #expect(headers["X-Msh-Device-Name"] != nil)
        #expect(headers["X-Msh-Device-Model"] != nil)
        #expect(headers["X-Msh-Os-Version"] != nil)
        #expect(headers["X-Msh-Device-Id"] != nil)
    }

    @Test("requestHeaders uses default version 1.0")
    func requestHeadersUsesDefaultVersion() {
        let headers = KimiCodeIdentity.requestHeaders()
        #expect(headers["User-Agent"] == "kimi-code-cli/1.0")
        #expect(headers["X-Msh-Version"] == "1.0")
    }

    @Test("requestHeaders version appears in User-Agent and X-Msh-Version")
    func requestHeadersVersionPropagation() {
        let headers = KimiCodeIdentity.requestHeaders(version: "3.5.2")
        #expect(headers["User-Agent"] == "kimi-code-cli/3.5.2")
        #expect(headers["X-Msh-Version"] == "3.5.2")
    }

    @Test("requestHeaders device name is non-empty string")
    func requestHeadersDeviceNameIsNonEmpty() {
        let headers = KimiCodeIdentity.requestHeaders()
        let deviceName = try! #require(headers["X-Msh-Device-Name"])
        #expect(!deviceName.isEmpty)
    }

    @Test("requestHeaders OS version is non-empty string")
    func requestHeadersOSVersionIsNonEmpty() {
        let headers = KimiCodeIdentity.requestHeaders()
        let osVersion = try! #require(headers["X-Msh-Os-Version"])
        #expect(!osVersion.isEmpty)
    }

    // MARK: - deviceModel

    // MARK: - Cross-field consistency

    @Test("requestHeaders device model and device ID are stable across calls")
    func requestHeadersDeviceFieldsStable() {
        let h1 = KimiCodeIdentity.requestHeaders()
        let h2 = KimiCodeIdentity.requestHeaders()

        #expect(h1["X-Msh-Device-Model"] == h2["X-Msh-Device-Model"])
        #expect(h1["X-Msh-Device-Id"] == h2["X-Msh-Device-Id"])
    }
}
