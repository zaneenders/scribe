# ScribeCLI

The `scribe` command-line tool — a fullscreen TUI application for interactive
coding sessions with the agent.

## Chat

The default subcommand starts an interactive chat session with full transcript,
LLM streaming, tool-call rounds, and session persistence.

## `scribe _edit`

An experimental scratch-buffer editor for testing modal text editing before it
merges into the chat input box.

```
$ swift run scribe _edit
```

Starts in **edit mode** — type, backspace, `Shift+Enter` for newlines.
The bottom strip shows an `EDIT:` label and your text.

### Mode toggling

| Key | From | To | Notes |
|-----|------|----|-------|
| `Ctrl+C` | edit | read | Switch to read (navigation) mode |
| `Escape` | edit | read | Same as `Ctrl+C` |
| `Enter` | read | edit | Enter typing mode at the current cursor |
| `Ctrl+C` | read | — | Quit |
| `Ctrl+D` | either | — | Quit from anywhere |

### Current limitations

- No arrow-key cursor movement yet
- Cursor glyph always renders at end of input (visual position not yet wired)
- No forward-delete (`.delete` key incoming from slate's `scribe#edit` branch)
- No bracketed-paste handling in the editor host
- Read mode has no navigation keys beyond `Enter` and `Ctrl+C`
