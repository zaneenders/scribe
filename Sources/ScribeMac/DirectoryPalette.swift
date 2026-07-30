import Chroma
import Foundation

/// The `$ cd` palette for choosing a session's working directory, shown both
/// as the required first-run screen and as an overlay on the ready UI.
struct DirectoryPalette: Block {
  let store: ScribeMacStore
  let theme: MacTheme
  let required: Bool

  @MainActor var body: some Block {
    VStack(spacing: 10, alignment: .leading) {
      if required {
        Text("Choose a project directory").fontScale(theme.textScale).foregroundColor(theme.accent)
        WrappedText(
          text: "Type a path and press Enter to start a session there. Tab completes directory names.",
          theme: theme, color: theme.textSecondary)
      } else {
        Text("Change directory").fontScale(theme.textScale).foregroundColor(theme.accent)
        WrappedText(
          text: "Starts a new session in the chosen directory. Tab completes directory names.",
          theme: theme, color: theme.textSecondary)
      }
      HStack(spacing: 6) {
        Text("$ cd").fontScale(theme.textScale).foregroundColor(theme.green)
        TextField(
          required ? "/path/to/project" : "path",
          id: ScribeMacStore.directoryPaletteID,
          fontScale: theme.textScale,
          text: { store.directoryDraft },
          onChange: { store.updateDirectoryDraft($0) },
          // Chroma fires onChange before onSubmit within a frame, so
          // `directoryDraft` already holds the sanitized text — submit with no
          // argument to use it rather than the field's raw buffer.
          onSubmit: { _ in store.submitDirectory() }
        )
      }
      if !store.directoryError.isEmpty {
        Text(sanitizeASCII(store.directoryError))
          .fontScale(theme.smallScale)
          .foregroundColor(theme.errorText)
      }
      if !store.directoryMatches.isEmpty {
        VStack(spacing: 2, alignment: .leading) {
          Text("Matches")
            .fontScale(theme.smallScale)
            .foregroundColor(theme.textSecondary)
          for match in store.directoryMatches.prefix(8) {
            Text(sanitizeASCII(match))
              .fontScale(theme.smallScale)
              .foregroundColor(theme.textPrimary)
          }
          if store.directoryMatches.count > 8 {
            Text("+\(store.directoryMatches.count - 8) more")
              .fontScale(theme.smallScale)
              .foregroundColor(theme.textSecondary)
          }
        }
      }
      if !required {
        HStack(spacing: 8) {
          Button("Cancel", id: WidgetID("directory-cancel"), fontScale: theme.smallScale) {
            store.closeDirectoryPicker()
          }
        }
      }
      if required {
        Spacer()
      }
    }
    .padding(theme.margin)
    .frame(maxWidth: required ? .infinity : 640, maxHeight: required ? .infinity : nil, alignment: .topLeading)
    .background(theme.headerBackground)
    .border(theme.border)
  }
}
