import ScribeLLM
import _RopeModule

// MARK: - MessageRope

/// A `Rope<Message>` specialised for chat history.
///
/// Wraps swift-collections `Rope<Message>` and exposes a chat-friendly API:
/// append single messages, extract viewport windows, truncate, iterate.
public struct MessageRope: Sendable {
    public typealias _Rope = Rope<Message>

    private var _rope: _Rope

    // MARK: - Init

    public init() {
        self._rope = Rope()
    }

    /// Bulk-load from an array of messages, chunked into leaves of up to 32.
    public init(_ messages: [Components.Schemas.ChatMessage]) {
        var elements: [Message] = []
        var chunk: [Components.Schemas.ChatMessage] = []
        chunk.reserveCapacity(MessageSummary.maxNodeSize)
        for msg in messages {
            chunk.append(msg)
            if chunk.count >= MessageSummary.maxNodeSize {
                elements.append(Message(messages: chunk))
                chunk = []
            }
        }
        if !chunk.isEmpty {
            elements.append(Message(messages: chunk))
        }
        self._rope = Rope()
        for el in elements {
            _rope.append(el)
        }
    }

    internal init(_rope: _Rope) {
        self._rope = _rope
    }

    // MARK: - Properties

    public var count: Int {
        _rope.count(in: MessageMetric())
    }

    public var isEmpty: Bool {
        _rope.isEmpty
    }

    public var first: Components.Schemas.ChatMessage? {
        guard !isEmpty, let leaf = _rope.first else { return nil }
        return leaf.messages.first
    }

    public var last: Components.Schemas.ChatMessage? {
        guard !isEmpty, let leaf = _rope.last else { return nil }
        return leaf.messages.last
    }

    // MARK: - Append

    public mutating func append(_ message: Components.Schemas.ChatMessage) {
        _rope.append(Message(messages: [message]))
    }

    // MARK: - Window

    /// Return `requestedCount` messages starting at `start` (0-indexed).
    public func window(from start: Int, count requestedCount: Int) -> [Components.Schemas.ChatMessage] {
        guard start >= 0, requestedCount > 0, !isEmpty else { return [] }
        let metric = MessageMetric()
        let total = _rope.count(in: metric)
        guard start < total else { return [] }
        let end = min(start + requestedCount, total)
        var result: [Components.Schemas.ChatMessage] = []
        result.reserveCapacity(end - start)

        // Find the start index and walk forward collecting messages.
        var idx = _rope.startIndex
        var offset = 0
        // Advance idx past leaves that end before `start`.
        while idx < _rope.endIndex {
            let leaf = _rope[idx]
            let leafCount = leaf.messages.count
            if offset + leafCount > start { break }
            offset += leafCount
            _rope.formIndex(after: &idx)
        }

        // Collect from the first overlapping leaf.
        if idx < _rope.endIndex {
            let leaf = _rope[idx]
            let localStart = start - offset
            let take = min(leaf.messages.count - localStart, end - start)
            result.append(contentsOf: leaf.messages[localStart ..< localStart + take])
            _rope.formIndex(after: &idx)
        }

        // Collect remaining full leaves.
        while result.count < end - start, idx < _rope.endIndex {
            let leaf = _rope[idx]
            let take = min(leaf.messages.count, end - start - result.count)
            result.append(contentsOf: leaf.messages.prefix(take))
            _rope.formIndex(after: &idx)
        }

        return result
    }

    // MARK: - Truncate

    public mutating func truncate(to newCount: Int) {
        precondition(newCount >= 0, "truncate count must be >= 0")
        let current = count
        guard newCount < current else { return }
        if newCount == 0 {
            self._rope = Rope()
            return
        }

        let metric = MessageMetric()
        _rope.removeSubrange(newCount ..< current, in: metric)
    }

    // MARK: - forEach

    public func forEach(_ body: (Components.Schemas.ChatMessage) throws -> Void) rethrows {
        for leaf in _rope {
            for msg in leaf.messages {
                try body(msg)
            }
        }
    }
}
