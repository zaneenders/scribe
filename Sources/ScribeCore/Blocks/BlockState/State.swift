import Observation

@propertyWrapper
public struct State<Value> {
    private let _storage: ObservedStorage<Value>

    public init(wrappedValue: Value) {
        self._storage = ObservedStorage(wrappedValue)
    }

    public var wrappedValue: Value {
        get {
            _storage.value
        }
        nonmutating set {
            _storage.value = newValue
        }
    }

    public var projectedValue: Binding<Value> {
        Binding(
            get: {
                self.wrappedValue
            },
            set: { newValue in
                self.wrappedValue = newValue
            })
    }
}
