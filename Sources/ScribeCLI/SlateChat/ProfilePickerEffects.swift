struct ProfilePickerEffects {
  var needsRender: Bool = false
  var applyModel: ApplyModelRequest?

  static let none = ProfilePickerEffects()
}

struct ApplyModelRequest: Equatable {
  var name: String
  var previousName: String
}
