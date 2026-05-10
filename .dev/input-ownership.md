# Plan: Move buffer ownership from slate → scribe

## Principle

Slate emits what key was pressed (paste-aware enter→newline conversion,
bracketed-paste tracking). Scribe owns the input buffer, modal editing logic,
and mode-specific key dispatch.

---

## 1. Slate changes (`../slate`)

### 1a. Strip `TerminalInputHandler` to a pure decoder

**Remove:**
- `buffer: String`
- `isEditing: Bool`
- `takeBuffer()` / `setBuffer(_:)`
- `applyBufferMutations(_:)`

**Keep:**
- `inPaste` tracking + paste-mode key conversion (enter→newline, tab→tab,
  backspace suppressed during paste)
- `keyDecoder`
- `handle(_:)` — returns `[TerminalInputAction]` with zero side effects

### 1b. Add missing cases to `TerminalInputAction`

- `escape` — was silently dropped by `default: break`
- `bracketedPasteStart` / `bracketedPasteEnd` — emitted so host can track
  paste state if needed

### 1c. Update demo app (`SlateDemoEntry`)

Currently calls `state.input.takeBuffer()` and reads `state.input.buffer`.
Give it a `var inputBuffer = ""` and mutate it from actions, following the
same pattern scribe will use.

---

## 2. Scribe changes (`SlateChatHost.swift`)

### 2a. Own the buffer

```swift
private var inputBuffer: String = ""
```

### 2b. Replace every `inputHandler.*` touchpoint

| Line | Current                         | New                                 |
|------|---------------------------------|-------------------------------------|
| 446  | `inputHandler.isEditing = ...`  | **delete**                          |
| 456  | `inputHandler.takeBuffer()`     | take `inputBuffer`, then `= ""`     |
| 469  | `inputHandler.setBuffer(recall)`| `inputBuffer = recall`              |
| 504  | `inputHandler.buffer.count`     | `inputBuffer.count`                 |
| 509  | `// Buffer already mutated...`  | **delete comment**                  |
| 559  | `inputHandler.buffer`           | `inputBuffer`                       |
| 575  | `inputHandler.buffer`           | `inputBuffer`                       |
| 595  | `inputHandler.buffer.count`     | `inputBuffer.count`                 |

### 2c. Do buffer mutations in the action switch

Remove the catch-all:

```swift
case .character, .backspace, .tab:
    break  // Buffer already mutated by TerminalInputHandler
```

Replace with explicit per-mode handling:

```swift
case .character(let ch):
    if self.editMode == .edit { self.inputBuffer.append(ch) }
case .backspace:
    if self.editMode == .edit, !self.inputBuffer.isEmpty {
        self.inputBuffer.removeLast()
    }
case .newline:
    if self.editMode == .edit { self.inputBuffer.append("\n") }
case .tab:
    if self.editMode == .edit { self.inputBuffer.append("    ") }
case .bracketedPasteStart, .bracketedPasteEnd:
    break  // slate already tracks inPaste for enter→newline conversion
```

In read mode: character/backspace/newline/tab keys are **no-ops**.  Read mode
is strictly arrow-key transcript scrolling, Enter→edit, Ctrl+C→ladder,
Ctrl+D→quit.

---

## 3. Migration order

1. Update `../slate` `TerminalInputHandler` + `TerminalInputAction`
2. Update `../slate` demo app
3. Update scribe `SlateChatHost`
4. Build & test (349 tests must stay green)

---

## 4. Aftermath

Once this lands, `Package.swift` can flip back from `path: "../slate"` to a
remote URL pinned to the new slate revision (after those changes are pushed
to the slate repo).
