import Foundation
import Logging
import ScribeCore
import ScribeLLM
import SlateCore

// MARK: - ChatDriver

/// Runs a chat session headlessly — no terminal, no Slate.
///
/// Input is provided programmatically; transcript snapshots are collected
/// after each event.  Designed for testing and maybe future non-TUI modes
/// (e.g., a web UI, a REPL mode).
public struct ChatDriver: Sendable {

  // MARK: - Config

  /// Configuration for a headless run.
  public struct Config: Sendable {
    /// The agent to run.
    public var agent: ScribeAgent
    /// Theme for render output.
    public var theme: CLITheme
    /// If true, collect a `RenderOutput` snapshot after every `TranscriptEvent`.
    public var captureEveryEvent: Bool
    /// Virtual terminal width for frame rendering.
    public var terminalCols: Int
    /// Virtual terminal height for frame rendering.
    public var terminalRows: Int

    public init(
      agent: ScribeAgent,
      theme: CLITheme = .default,
      captureEveryEvent: Bool = true,
      terminalCols: Int = 120,
      terminalRows: Int = 40
    ) {
      self.agent = agent
      self.theme = theme
      self.captureEveryEvent = captureEveryEvent
      self.terminalCols = terminalCols
      self.terminalRows = terminalRows
    }
  }

  // MARK: - Init

  public init() {}

  // MARK: - Run

  /// Run the chat loop with the given input lines.  Returns a history of
  /// transcript states and a final result.
  ///
  /// The input stream is consumed until the agent finishes all turns
  /// (each line triggers one model turn, or "exit" to stop).
  public func run(
    config: Config,
    input: [String],
    log: Logger
  ) async throws -> RunResult {
    let markdownRenderer: MarkdownRenderer = SwiftMarkdownRenderer()
    var transcriptController = TranscriptController()
    var history: [TranscriptSnapshot] = []

    // Feed each input line as a user turn.
    var finalMessages: [Components.Schemas.ChatMessage] = []
    var finalOutcome: TurnOutcome = .completed

    for line in input {
      let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
      if trimmed == "exit" {
        log.notice("event=chat.headless.exit-command")
        break
      }
      if trimmed.isEmpty {
        log.trace("event=chat.headless.empty-skip")
        continue
      }

      // Emit user-submitted event.
      let userEvent = TranscriptEvent.userSubmitted(trimmed)
      _ = transcriptController.apply(userEvent, theme: config.theme, renderer: markdownRenderer)
      if config.captureEveryEvent {
        history.append(makeSnapshot(userEvent, controller: transcriptController))
      }

      // Run the model turn.
      log.debug("event=chat.headless.turn.dispatch", metadata: ["chars": "\(trimmed.count)"])
      let stream = await config.agent.prompt(trimmed, log: log)

      // Drain streaming events into transcript controller.
      for await event in stream.events {
        _ = transcriptController.apply(event, theme: config.theme, renderer: markdownRenderer)
        if config.captureEveryEvent {
          history.append(makeSnapshot(event, controller: transcriptController))
        }
      }

      // Collect the result.
      do {
        let result = try await stream.result.value
        finalMessages = result.messages
        finalOutcome = result.outcome
        log.info(
          "event=chat.headless.turn.end",
          metadata: ["outcome": "\(result.outcome)"])
      } catch {
        let se = (error as? ScribeError) ?? .generic(String(describing: error))
        log.error(
          "event=chat.headless.turn.error",
          metadata: ["err": "\(se.errorDescription ?? String(describing: se))"])
        let errorEvent = TranscriptEvent.harnessError(se)
        _ = transcriptController.apply(errorEvent, theme: config.theme, renderer: markdownRenderer)
        if config.captureEveryEvent {
          history.append(makeSnapshot(errorEvent, controller: transcriptController))
        }
        throw error
      }
    }

    // Build final render frame.
    let finalRender = buildFrame(
      controller: transcriptController,
      theme: config.theme,
      cols: config.terminalCols,
      rows: config.terminalRows
    )

    return RunResult(
      outcome: finalOutcome,
      messages: finalMessages,
      transcriptHistory: history,
      finalTranscript: transcriptController.completedLines,
      finalRender: finalRender
    )
  }

  // MARK: - Helpers

  private func makeSnapshot(
    _ event: TranscriptEvent,
    controller: TranscriptController
  ) -> TranscriptSnapshot {
    TranscriptSnapshot(
      event: event,
      completedLines: controller.completedLines,
      streamingOpenLine: controller.streamingOpenLine
    )
  }

  /// Build a `RenderOutput` from the current transcript state (pure function).
  ///
  /// Renders the flattened transcript into simple text lines — no TUI grid needed.
  /// Each `TLine` becomes one text line with ANSI-like prefix markers stripped.
  private func buildFrame(
    controller: TranscriptController,
    theme: CLITheme,
    cols: Int,
    rows: Int
  ) -> RenderOutput {
    let completed = controller.completedLines
    let open = controller.streamingOpenLine
    let generation = controller.generation

    var cache = TranscriptLayout.FlattenCache()
    let flatTranscript = TranscriptLayout.FlattenCache.flatten(
      cache: &cache,
      completed: completed,
      open: open,
      width: cols,
      generation: generation
    )

    // Convert flattened TLine array to plain text lines.
    let textLines = flatTranscript.map { line in
      line.spans.map { $0.text }.joined()
    }

    // Build RenderCell rows from text.
    let renderedLines: [RenderLine] = textLines.enumerated().map { (i, text) in
      var cells: [RenderCell] = []
      for (j, ch) in text.enumerated() {
        // Use the first span's styling if available.
        let span = i < flatTranscript.count && j < flatTranscript[i].spans.count
          ? flatTranscript[i].spans.first : nil
        cells.append(RenderCell(
          glyph: ch,
          foreground: span?.fg ?? theme.inputText,
          background: span?.bg ?? theme.background,
          bold: span?.bold ?? false))
      }
      // Pad to full width with spaces.
      while cells.count < cols {
        cells.append(RenderCell(
          glyph: " ",
          foreground: theme.inputText,
          background: theme.background,
          bold: false))
      }
      return RenderLine(cells: cells)
    }

    return RenderOutput(
      cols: cols,
      rows: rows,
      flatTranscript: flatTranscript,
      renderedLines: renderedLines
    )
  }
}

// MARK: - RunResult

/// The result of a headless chat run.
public struct RunResult: Sendable {
  /// How the final turn ended.
  public var outcome: TurnOutcome
  /// The final conversation messages.
  public var messages: [Components.Schemas.ChatMessage]
  /// Transcript snapshots after each event (if `captureEveryEvent` was true).
  public var transcriptHistory: [TranscriptSnapshot]
  /// The final transcript (completed lines).
  public var finalTranscript: [TLine]
  /// The final render output.
  public var finalRender: RenderOutput

  public init(
    outcome: TurnOutcome,
    messages: [Components.Schemas.ChatMessage],
    transcriptHistory: [TranscriptSnapshot],
    finalTranscript: [TLine],
    finalRender: RenderOutput
  ) {
    self.outcome = outcome
    self.messages = messages
    self.transcriptHistory = transcriptHistory
    self.finalTranscript = finalTranscript
    self.finalRender = finalRender
  }
}

// MARK: - RenderOutput

/// A snapshot of the rendered terminal grid, inspectable in tests.
public struct RenderOutput: Equatable, Sendable {
  /// Grid width in cells.
  public var cols: Int
  /// Grid height in cells.
  public var rows: Int
  /// The flattened transcript that was rendered.
  public var flatTranscript: [TLine]
  /// The rendered cell grid, row by row.
  public var renderedLines: [RenderLine]

  public init(
    cols: Int,
    rows: Int,
    flatTranscript: [TLine],
    renderedLines: [RenderLine]
  ) {
    self.cols = cols
    self.rows = rows
    self.flatTranscript = flatTranscript
    self.renderedLines = renderedLines
  }

  /// Extract the plain text visible in the rendered grid (strips ANSI formatting).
  public var visibleText: String {
    renderedLines.map { line in
      line.cells.map { String($0.glyph) }.joined()
    }.joined(separator: "\n")
  }

  /// Returns all cells on the given row.
  public func row(_ index: Int) -> RenderLine? {
    guard index >= 0, index < renderedLines.count else { return nil }
    return renderedLines[index]
  }

  /// Search the rendered output for a row containing `substring`.
  public func firstRow(containing substring: String) -> Int? {
    for (i, line) in renderedLines.enumerated() {
      let text = line.cells.map { String($0.glyph) }.joined()
      if text.contains(substring) {
        return i
      }
    }
    return nil
  }
}

/// One row of rendered cells.
public struct RenderLine: Equatable, Sendable {
  public var cells: [RenderCell]

  public init(cells: [RenderCell]) {
    self.cells = cells
  }

  /// Plain text of this row.
  public var text: String {
    cells.map { String($0.glyph) }.joined()
  }
}

/// One cell in the rendered grid.
public struct RenderCell: Equatable, Sendable {
  public var glyph: Character
  public var foreground: TerminalRGB
  public var background: TerminalRGB
  public var bold: Bool

  public init(
    glyph: Character,
    foreground: TerminalRGB,
    background: TerminalRGB,
    bold: Bool
  ) {
    self.glyph = glyph
    self.foreground = foreground
    self.background = background
    self.bold = bold
  }
}
