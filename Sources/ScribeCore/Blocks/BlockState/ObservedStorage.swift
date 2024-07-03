import Observation

final class ObservedStorage<Value>: Observation.Observable {

    @ObservationIgnored
    private var _value: Value

    var value: Value
    {
        @storageRestrictions(initializes: _value)
        init(initialValue) {
            _value = initialValue
        }
        get {
            access(keyPath: \.value)
            return _value
        }
        set {
            withMutation(keyPath: \.value) {
                _value = newValue
            }
        }
    }

    init(_ value: Value) {
        self.value = value
    }

    @ObservationIgnored
    private let _$observationRegistrar =
        Observation.ObservationRegistrar()

    internal nonisolated func access<Member>(
        keyPath: KeyPath<ObservedStorage, Member>
    ) {
        _$observationRegistrar.access(self, keyPath: keyPath)
    }

    internal nonisolated func withMutation<Member, MutationResult>(
        keyPath: KeyPath<ObservedStorage, Member>,
        _ mutation: () throws -> MutationResult
    ) rethrows -> MutationResult {
        try _$observationRegistrar.withMutation(
            of: self, keyPath: keyPath, mutation)
    }
}
