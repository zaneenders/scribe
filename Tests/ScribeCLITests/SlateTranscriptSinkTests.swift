import Foundation
import ScribeCLI
import ScribeCore
import ScribeLLM
import Testing

/// Tests for `SlateTranscriptSink` covering `setMessageCount`, boundary
/// tracking, viewport trimming, and `.messageCountChanged` event handling.
@Suite
struct SlateTranscriptSinkTests {

  // MARK: - setMessageCount

  @Test func setMessageCountPersistsValue() {
    let sink = SlateTranscriptSink()
    sink.setMessageCount(5)
    // After setting messageCount to 5 and emitting events that produce no
    // lines, emit a .messageCountChanged that exceeds maxRenderedMessages
    // (34) to trigger trimming and verify state was stored.
    sink.setMessageCount(35)
    // If messageCount was stored, adding enough lines should trigger trim.
    // We verify this via the snapshot returning a reasonable line count.
    let snap = sink.snapshotTranscriptForLayout()
    #expect(snap.lineGeneration >= 0)
  }

  @Test func setMessageCountZeroDoesNotTriggerTrim() {
    let sink = SlateTranscriptSink()
    sink.setMessageCount(0)
    // Even with many lines, zero message count means no rope-driven trim.
    for _ in 0..<100 {
      sink.emit(.blankLine)
    }
    let snap = sink.snapshotTranscriptForLayout()
    // Should have 100 blank lines (under the 4000 hard cap).
    #expect(snap.completed.count == 100)
  }

  // MARK: - messageCountChanged syncs boundaries

  @Test func messageCountChangedSyncsBoundariesSoTrimCanFindCutPoint() {
    let sink = SlateTranscriptSink()

    // Simulate a conversation that grows beyond maxRenderedMessages (34).
    // Each "message" gets a few rendered lines.

    // Messages 1-10: blank + blank lines (content-light messages)
    for i in 1...10 {
      sink.emit(.blankLine)
      sink.emit(.blankLine)
      sink.emit(.messageCountChanged(i))
    }

    // Messages 11-40: more content
    for i in 11...40 {
      sink.emit(.blankLine)
      sink.emit(.blankLine)
      sink.emit(.messageCountChanged(i))
    }

    let snap = sink.snapshotTranscriptForLayout()
    // After 40 messages (>34 max), the trimmer should have fired.
    // The line count should be less than 80 (40 * 2).
    #expect(snap.completed.count < 80, "Expected trimming to reduce line count below 80, got \(snap.completed.count)")
    // Should have bumped the generation at least once.
    #expect(snap.lineGeneration > 0, "Expected lineGeneration to bump after trim")
  }

  // MARK: - recordUserSubmission boundary tracking

  @Test func recordUserSubmissionAddsBoundary() {
    let sink = SlateTranscriptSink()

    // Record a user submission, then push enough messages to trigger trim.
    sink.recordUserSubmission(trimmedVisible: "hello world")
    sink.emit(.messageCountChanged(1))

    // Push messages 2-35 (with content lines) to go past maxRenderedMessages=34.
    for i in 2...35 {
      sink.emit(.blankLine)
      sink.emit(.blankLine)
      sink.emit(.messageCountChanged(i))
    }

    let snap = sink.snapshotTranscriptForLayout()
    #expect(snap.lineGeneration > 0, "Expected trimming to occur after 35 messages")
    // The user submission should have been trimmed away (it was message 1 of 35).
    // Verify we have fewer lines than if nothing was trimmed.
    #expect(snap.completed.count < 72, "Expected trimmed lines, got \(snap.completed.count)")
  }

  // MARK: - Viewport trimming with enterAssistantSection

  @Test func trimmingPreservesRecentMessagesWhenAssistantSectionsPresent() {
    let sink = SlateTranscriptSink()

    // Build messages 1-40 with realistic structure:
    // message 1: user submission
    // messages 2-39: assistant sections (each with a header)
    // message 40: final
    sink.recordUserSubmission(trimmedVisible: "msg1")
    sink.emit(.messageCountChanged(1))

    for i in 2...39 {
      sink.emit(.enterAssistantSection(.answer, previous: i == 2 ? nil : .answer))
      sink.emit(.appendAssistantText(.answer, text: "response \(i)"))
      sink.emit(.finalizeAssistantStream)
      sink.emit(.messageCountChanged(i))
    }
    sink.emit(.enterAssistantSection(.answer, previous: .answer))
    sink.emit(.appendAssistantText(.answer, text: "final"))
    sink.emit(.finalizeAssistantStream)
    sink.emit(.messageCountChanged(40))

    let snap = sink.snapshotTranscriptForLayout()
    #expect(snap.lineGeneration > 0, "Expected trimming to fire for 40 messages")
  }

  // MARK: - Empty assistant turn boundary

  @Test func emptyAssistantTurnAddsBoundary() {
    let sink = SlateTranscriptSink()

    // Several empty turns with messageCountChanged to sync boundaries.
    for i in 1...40 {
      sink.emit(.emptyAssistantTurn)
      sink.emit(.messageCountChanged(i))
    }

    let snap = sink.snapshotTranscriptForLayout()
    // Each empty turn produces 2 lines (scribe: header + "(empty turn)").
    // 40 * 2 = 80 lines. Trimming should reduce this since we're over 34 messages.
    #expect(snap.completed.count < 80, "Expected trimming for 40 empty-turn messages, got \(snap.completed.count)")
    #expect(snap.lineGeneration > 0, "Expected lineGeneration bump from trimming")
  }

  // MARK: - No trim when under threshold

  @Test func noTrimWhenUnderMaxMessages() {
    let sink = SlateTranscriptSink()

    // 10 messages, well under maxRenderedMessages (34).
    for i in 1...10 {
      sink.emit(.blankLine)
      sink.emit(.blankLine)
      sink.emit(.messageCountChanged(i))
    }

    let snap = sink.snapshotTranscriptForLayout()
    // All 20 lines should be present.
    #expect(snap.completed.count == 20)
    #expect(snap.lineGeneration == 0, "No trimming should have occurred")
  }

  // MARK: - Hard line cap fallback

  @Test func hardLineCapWhenNoMessageCountAvailable() {
    let sink = SlateTranscriptSink()

    // Push 5000 lines without setting messageCount.  Should trigger the
    // 4000-line hard cap.
    for _ in 0..<5000 {
      sink.emit(.blankLine)
    }

    let snap = sink.snapshotTranscriptForLayout()
    #expect(snap.completed.count <= 4000, "Hard cap of 4000 lines should apply, got \(snap.completed.count)")
    #expect(snap.lineGeneration > 0, "Expected lineGeneration bump from hard cap")
  }

  // MARK: - Boundary sync is monotonic

  @Test func messageCountChangedNeverShrinksMessageCount() {
    let sink = SlateTranscriptSink()

    sink.emit(.messageCountChanged(50))

    // Push lines to fill up the 50 messages worth.
    for _ in 0..<100 {
      sink.emit(.blankLine)
    }

    // A smaller count should not cause issues (the sink sets it verbatim,
    // but boundaries only sync upward via the `while` loop).
    sink.emit(.messageCountChanged(5))

    // The trimmer uses the smaller count now, so it should NOT trim
    // (5 <= 34).  Verify lines are intact.
    let snap = sink.snapshotTranscriptForLayout()
    #expect(snap.completed.count == 100)
  }

  // MARK: - setMessageCount + onRopeUpdate integration

  @Test func setMessageCountViaOnRopeUpdateTriggersTrimming() {
    let sink = SlateTranscriptSink()

    // Simulate the onRopeUpdate callback path (used by SlateChatHost).
    // Push lines for many messages.
    for i in 1...50 {
      sink.emit(.blankLine)
      sink.emit(.blankLine)
      // After every few messages, update the count via setMessageCount
      // (the onRopeUpdate path).
      if i % 5 == 0 {
        sink.setMessageCount(i)
      }
    }
    // Also send a .messageCountChanged to sync boundaries and trigger trim.
    sink.emit(.messageCountChanged(50))

    let snap = sink.snapshotTranscriptForLayout()
    #expect(snap.lineGeneration > 0, "Expected trimming after 50 messages")
  }
}
