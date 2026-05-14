# ScribeCLI

The `scribe` command-line tool — a fullscreen TUI application for interactive
coding sessions with the agent.

## Chat

The default subcommand starts an interactive chat session with full transcript,
LLM streaming, tool-call rounds, and session persistence.

### Mode toggling

| Key | From | To | Notes |
|-----|------|----|-------|
| `Ctrl+C` | edit | read | Switch to read (navigation) mode |
| `Escape` | edit | read | Same as `Ctrl+C` |
| `Enter` | read | edit | Enter typing mode at the current cursor |
| `Ctrl+C` | read | — | Quit |
| `Ctrl+D` | either | — | Quit from anywhere
