import Foundation
import OpenAPIRuntime

// MARK: - SSE chunk constructors

/// Creates an SSE `data:` chunk from a JSON payload.
func sseChunk(_ json: String) -> HTTPBody.ByteChunk {
    ArraySlice("data: \(json)\n\n".utf8)
}

/// The SSE `[DONE]` sentinel chunk.
let doneSSEChunk: HTTPBody.ByteChunk = ArraySlice("data: [DONE]\n\n".utf8)

/// Convenience function returning the `[DONE]` sentinel chunk.
func doneChunk() -> HTTPBody.ByteChunk {
    doneSSEChunk
}

/// Builds an SSE string from JSON payloads. Each payload becomes
/// a `data:` field of an SSE event, terminated with `\n\n`.
func makeSSE(_ events: String...) -> String {
    events.map { "data: \($0)\n\n" }.joined()
}

/// Creates an `HTTPBody` from SSE payload strings.
func sse(_ payloads: String...) -> HTTPBody {
    HTTPBody(payloads.map { "data: \($0)\n\n" }.joined())
}

/// Creates an array of SSE chunks, one per JSON payload.
func sseChunks(_ payloads: String...) -> [HTTPBody.ByteChunk] {
    payloads.map { sseChunk($0) }
}
