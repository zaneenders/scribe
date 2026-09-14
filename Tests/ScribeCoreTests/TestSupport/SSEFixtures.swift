import Foundation
import OpenAPIRuntime

func sseChunk(_ json: String) -> HTTPBody.ByteChunk {
  ArraySlice("data: \(json)\n\n".utf8)
}

let doneSSEChunk: HTTPBody.ByteChunk = ArraySlice("data: [DONE]\n\n".utf8)

func doneChunk() -> HTTPBody.ByteChunk {
  doneSSEChunk
}

func makeSSE(_ events: String...) -> String {
  events.map { "data: \($0)\n\n" }.joined()
}

func sse(_ payloads: String...) -> HTTPBody {
  HTTPBody(payloads.map { "data: \($0)\n\n" }.joined())
}

func sseChunks(_ payloads: String...) -> [HTTPBody.ByteChunk] {
  payloads.map { sseChunk($0) }
}
