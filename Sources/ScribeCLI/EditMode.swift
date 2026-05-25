
/// The two modal states for the input box (used by the chat host).
///
/// ## Mode transitions
///
/// ```
/// ┌──────┐  Ctrl+C / Escape   ┌──────┐
/// │ edit │ ──────────────────→ │ read │
/// │      │ ←────────────────── │      │
/// └──┬───┘       Enter         └──┬───┘
///    │ Enter (submit)             │ Ctrl+C (ladder)
///    ▼                            ▼
///   send                        interrupt / exit
/// ```
enum EditMode {
  /// Navigation mode: keys move the cursor, Enter switches to edit mode,
  /// Ctrl+C quits (or walks the ladder in chat).
  case read
  /// Typing mode: keys insert characters, Ctrl+C / Escape switches to read mode.
  case edit
}
