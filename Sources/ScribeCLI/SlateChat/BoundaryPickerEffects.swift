import ScribeCore

struct BoundaryPickerConfirmRequest: Sendable {
  var kind: PickerSnapshot.Kind
  var startCut: Int
  var endCut: Int
  var slice: [ScribeMessage]
  var messageCount: Int
}

struct BoundaryPickerEffects {
  var needsRender: Bool = false
  var confirm: BoundaryPickerConfirmRequest?

  static let none = BoundaryPickerEffects()
}
