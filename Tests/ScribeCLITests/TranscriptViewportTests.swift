import Foundation
import Testing

@testable import ScribeCLI


/// Tests for the `TranscriptViewport` scroll state machine — a pure function of
/// `(queued scroll deltas, flatCount, contentRows)` so it can be tested without a
/// running terminal.
@Suite
struct TranscriptViewportTests {


  @Test func initialFollowingLive() {
    let vp = TranscriptViewport()
    #expect(vp.followingLive == true)
    #expect(vp.firstVisibleRow == 0)
  }


  @Test func followModeTracksTail() {
    var vp = TranscriptViewport()
    // 100 flat lines, 20 content rows → tail starts at 80
    let first = vp.resolve(flatCount: 100, contentRows: 20)
    #expect(first == 80)
  }

  @Test func followModeTracksTailWhenFlatShorterThanContent() {
    var vp = TranscriptViewport()
    // Only 5 lines, 20 content rows → tail starts at 0
    let first = vp.resolve(flatCount: 5, contentRows: 20)
    #expect(first == 0)
  }


  @Test func scrollUpBreaksFollowMode() {
    var vp = TranscriptViewport()
    _ = vp.resolve(flatCount: 100, contentRows: 20)  // tail at 80
    vp.queueScroll(by: -1)
    let first = vp.resolve(flatCount: 100, contentRows: 20)
    #expect(first == 79)
    #expect(vp.followingLive == false)
  }

  @Test func scrollUpAtTopStaysAtZero() {
    var vp = TranscriptViewport()
    _ = vp.resolve(flatCount: 100, contentRows: 20)  // tail at 80
    vp.queueScroll(by: -200)
    let first = vp.resolve(flatCount: 100, contentRows: 20)
    #expect(first == 0)
    #expect(vp.followingLive == false)
  }


  @Test func scrollDownReachesBottomRestoresFollow() {
    var vp = TranscriptViewport()
    _ = vp.resolve(flatCount: 100, contentRows: 20)  // tail at 80

    // Scroll up, then scroll down past the bottom
    vp.queueScroll(by: -10)
    _ = vp.resolve(flatCount: 100, contentRows: 20)  // now at 70

    vp.queueScroll(by: 50)  // way past tail
    let first = vp.resolve(flatCount: 100, contentRows: 20)
    #expect(first == 80)
    #expect(vp.followingLive == true)
  }


  @Test func pageUpMovesByContentHeight() {
    var vp = TranscriptViewport()
    _ = vp.resolve(flatCount: 200, contentRows: 20)  // tail at 180
    vp.queuePageUp()
    let first = vp.resolve(flatCount: 200, contentRows: 20)
    #expect(first == 160)
    #expect(vp.followingLive == false)
  }

  @Test func pageDownMovesByContentHeight() {
    var vp = TranscriptViewport()
    _ = vp.resolve(flatCount: 200, contentRows: 20)  // tail at 180
    vp.queueScroll(by: -40)
    _ = vp.resolve(flatCount: 200, contentRows: 20)  // at 140
    vp.queuePageDown()
    let first = vp.resolve(flatCount: 200, contentRows: 20)
    #expect(first == 160)
  }


  @Test func goToTopSetsZeroAndExitsFollow() {
    var vp = TranscriptViewport()
    _ = vp.resolve(flatCount: 200, contentRows: 20)
    vp.queueGoToTop()
    let first = vp.resolve(flatCount: 200, contentRows: 20)
    #expect(first == 0)
    #expect(vp.followingLive == false)
  }

  @Test func goToBottomRestoresFollow() {
    var vp = TranscriptViewport()
    _ = vp.resolve(flatCount: 200, contentRows: 20)
    vp.queueGoToTop()
    _ = vp.resolve(flatCount: 200, contentRows: 20)  // at 0, not following

    vp.queueGoToBottom()
    let first = vp.resolve(flatCount: 200, contentRows: 20)
    #expect(first == 180)
    #expect(vp.followingLive == true)
  }


  @Test func contentShrinksWhileScrolledUpClampsToNewTail() {
    var vp = TranscriptViewport()
    _ = vp.resolve(flatCount: 200, contentRows: 20)  // tail at 180
    vp.queueGoToTop()
    _ = vp.resolve(flatCount: 200, contentRows: 20)  // at 0, not following

    // Transcript is truncated — flat count drops to 50
    let first = vp.resolve(flatCount: 50, contentRows: 20)
    #expect(first == 0)  // still at top, since 0 < new tail
  }

  @Test func contentShrinksBelowScrollPositionClamps() {
    var vp = TranscriptViewport()
    _ = vp.resolve(flatCount: 200, contentRows: 20)  // tail at 180
    vp.queueScroll(by: -20)
    _ = vp.resolve(flatCount: 200, contentRows: 20)  // at 160, not following

    // Flat count drops to 30 (tail = 10)
    let first = vp.resolve(flatCount: 30, contentRows: 20)
    #expect(first == 10)  // clamped to new tail
  }


  @Test func multipleScrollDeltasAccumulate() {
    var vp = TranscriptViewport()
    _ = vp.resolve(flatCount: 100, contentRows: 20)  // tail at 80

    vp.queueScroll(by: -5)
    vp.queueScroll(by: -3)
    vp.queueScroll(by: -2)
    let first = vp.resolve(flatCount: 100, contentRows: 20)
    #expect(first == 70)  // 80 - 10
  }


  @Test func zeroContentRowsReturnsFlatCount() {
    var vp = TranscriptViewport()
    // tail = flatCount - 0 = flatCount (all lines are "visible")
    let first = vp.resolve(flatCount: 100, contentRows: 0)
    #expect(first == 100)
  }
}
