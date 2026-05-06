import ScribeLLM
import _RopeModule

// MARK: - MessageMetric

/// Measures a `Message` in terms of raw message count.
public struct MessageMetric: RopeMetric {
    public typealias Element = Message

    public func size(of summary: MessageSummary) -> Int {
        summary.count
    }

    public func index(at offset: Int, in element: Message) -> Int {
        offset
    }
}
