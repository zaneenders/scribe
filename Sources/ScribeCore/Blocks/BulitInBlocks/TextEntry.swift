import Observation

public struct TextEntry: Block, BuiltinBlock {
    let type: BuiltinBlocks = .textEntry
    let storage: EntryStorage
    public init(_ initial: String) {
        self.storage = EntryStorage(initial)
    }
    public var component: some Block {
        Text(storage.text)
    }
}

@Observable
internal final class EntryStorage {
    var text: String
    init(_ text: String) {
        self.text = text
    }
}

extension EntryStorage: Equatable {
    /// This is not intended for external use only for testing.
    static func == (lhs: EntryStorage, rhs: EntryStorage) -> Bool {
        lhs.text == rhs.text
    }
}
extension EntryStorage {
    var testDescription: String {
        "EntryStorage(\"\(text)\")"
    }
}
