import Foundation
import ScribeCore
import Testing

/// Tests for `ScribeAgentResponse` and `ScribeAgentRequest` JSON encoding/decoding.
@Suite
struct ScribeAgentResponseTests {

    // MARK: - ScribeAgentRequest

    @Test func requestRoundTripsThroughJSON() throws {
        let original = ScribeAgentRequest(message: "list files in /tmp")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ScribeAgentRequest.self, from: data)
        #expect(decoded.message == original.message)
    }

    @Test func requestEncodesToExpectedJSON() throws {
        let request = ScribeAgentRequest(message: "hello")
        let data = try JSONEncoder().encode(request)
        let raw = String(data: data, encoding: .utf8) ?? ""
        #expect(raw.contains("\"message\""))
        #expect(raw.contains("\"hello\""))
    }

    // MARK: - ScribeAgentResponse.success

    @Test func successEncodesToExpectedJSON() throws {
        let response = ScribeAgentResponse.success(assistant: "done")
        let data = try JSONEncoder().encode(response)
        let decoded = try JSONDecoder().decode(ScribeAgentResponse.self, from: data)
        #expect(decoded.ok == true)
        #expect(decoded.assistant == "done")
        #expect(decoded.error == nil)
    }

    @Test func successJSONContainsExpectedKeys() throws {
        let response = ScribeAgentResponse.success(assistant: "result")
        let data = try JSONEncoder().encode(response)
        let raw = String(data: data, encoding: .utf8) ?? ""
        #expect(raw.contains("\"ok\":true") || raw.contains("\"ok\" : true"))
        #expect(raw.contains("\"assistant\":\"result\"") || raw.contains("\"assistant\" : \"result\""))
        #expect(!raw.contains("\"error\""))
    }

    // MARK: - ScribeAgentResponse.failure

    @Test func failureEncodesToExpectedJSON() throws {
        let response = ScribeAgentResponse.failure("something went wrong")
        let data = try JSONEncoder().encode(response)
        let decoded = try JSONDecoder().decode(ScribeAgentResponse.self, from: data)
        #expect(decoded.ok == false)
        #expect(decoded.assistant == nil)
        #expect(decoded.error == "something went wrong")
    }

    @Test func failureJSONContainsExpectedKeys() throws {
        let response = ScribeAgentResponse.failure("bad input")
        let data = try JSONEncoder().encode(response)
        let raw = String(data: data, encoding: .utf8) ?? ""
        #expect(raw.contains("\"ok\":false") || raw.contains("\"ok\" : false"))
        #expect(raw.contains("\"error\":\"bad input\"") || raw.contains("\"error\" : \"bad input\""))
    }

    // MARK: - Equatable

    @Test func successIsEquatable() {
        let a = ScribeAgentResponse.success(assistant: "x")
        let b = ScribeAgentResponse.success(assistant: "x")
        let c = ScribeAgentResponse.success(assistant: "y")
        #expect(a == b)
        #expect(a != c)
    }

    @Test func failureIsEquatable() {
        let a = ScribeAgentResponse.failure("err")
        let b = ScribeAgentResponse.failure("err")
        let c = ScribeAgentResponse.failure("other")
        #expect(a == b)
        #expect(a != c)
    }

    // MARK: - Edge cases

    @Test func handlesEmptyAssistantContent() throws {
        let response = ScribeAgentResponse.success(assistant: "")
        let data = try JSONEncoder().encode(response)
        let decoded = try JSONDecoder().decode(ScribeAgentResponse.self, from: data)
        #expect(decoded.ok == true)
        #expect(decoded.assistant == "")
    }

    @Test func handlesEmptyErrorMessage() throws {
        let response = ScribeAgentResponse.failure("")
        let data = try JSONEncoder().encode(response)
        let decoded = try JSONDecoder().decode(ScribeAgentResponse.self, from: data)
        #expect(decoded.ok == false)
        #expect(decoded.error == "")
    }
}
