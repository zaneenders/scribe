import Foundation

struct ProfilePickerSnapshot: Sendable, Equatable {
  var profiles: [ProfileSummary]
  var cursor: Int
  var activeName: String

  var profileCount: Int { profiles.count }

  var currentProfile: ProfileSummary {
    guard !profiles.isEmpty else {
      return ProfileSummary(name: "", model: "", baseURL: "")
    }
    let index = max(0, min(cursor, profiles.count - 1))
    return profiles[index]
  }
}
