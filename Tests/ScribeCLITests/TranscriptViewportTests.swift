import Foundation
import Testing

@testable import ScribeCLI
@testable import ScribeKit

@Suite
struct TranscriptViewportTests {

  @Test func initialFollowingLive() {
    let vp = TranscriptViewport()
    #expect(vp.followingLive == true)
    #expect(vp.firstVisibleRow == 0)
  }

  @Test func followModeTracksTail() {
    var vp = TranscriptViewport()

    let first = vp.resolve(flatCount: 100, contentRows: 20)
    #expect(first == 80)
  }

  @Test func followModeTracksTailWhenFlatShorterThanContent() {
    var vp = TranscriptViewport()

    let first = vp.resolve(flatCount: 5, contentRows: 20)
    #expect(first == 0)
  }

  @Test func scrollUpBreaksFollowMode() {
    var vp = TranscriptViewport()
    _ = vp.resolve(flatCount: 100, contentRows: 20)
    vp.queueScroll(by: -1)
    let first = vp.resolve(flatCount: 100, contentRows: 20)
    #expect(first == 79)
    #expect(vp.followingLive == false)
  }

  @Test func scrollUpAtTopStaysAtZero() {
    var vp = TranscriptViewport()
    _ = vp.resolve(flatCount: 100, contentRows: 20)
    vp.queueScroll(by: -200)
    let first = vp.resolve(flatCount: 100, contentRows: 20)
    #expect(first == 0)
    #expect(vp.followingLive == false)
  }

  @Test func scrollDownReachesBottomRestoresFollow() {
    var vp = TranscriptViewport()
    _ = vp.resolve(flatCount: 100, contentRows: 20)

    vp.queueScroll(by: -10)
    _ = vp.resolve(flatCount: 100, contentRows: 20)

    vp.queueScroll(by: 50)
    let first = vp.resolve(flatCount: 100, contentRows: 20)
    #expect(first == 80)
    #expect(vp.followingLive == true)
  }

  @Test func pageUpMovesByContentHeight() {
    var vp = TranscriptViewport()
    _ = vp.resolve(flatCount: 200, contentRows: 20)
    vp.queuePageUp()
    let first = vp.resolve(flatCount: 200, contentRows: 20)
    #expect(first == 160)
    #expect(vp.followingLive == false)
  }

  @Test func pageDownMovesByContentHeight() {
    var vp = TranscriptViewport()
    _ = vp.resolve(flatCount: 200, contentRows: 20)
    vp.queueScroll(by: -40)
    _ = vp.resolve(flatCount: 200, contentRows: 20)
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
    _ = vp.resolve(flatCount: 200, contentRows: 20)

    vp.queueGoToBottom()
    let first = vp.resolve(flatCount: 200, contentRows: 20)
    #expect(first == 180)
    #expect(vp.followingLive == true)
  }

  @Test func contentShrinksWhileScrolledUpClampsToNewTail() {
    var vp = TranscriptViewport()
    _ = vp.resolve(flatCount: 200, contentRows: 20)
    vp.queueGoToTop()
    _ = vp.resolve(flatCount: 200, contentRows: 20)

    let first = vp.resolve(flatCount: 50, contentRows: 20)
    #expect(first == 0)
  }

  @Test func contentShrinksBelowScrollPositionClamps() {
    var vp = TranscriptViewport()
    _ = vp.resolve(flatCount: 200, contentRows: 20)
    vp.queueScroll(by: -20)
    _ = vp.resolve(flatCount: 200, contentRows: 20)

    let first = vp.resolve(flatCount: 30, contentRows: 20)
    #expect(first == 10)
  }

  @Test func multipleScrollDeltasAccumulate() {
    var vp = TranscriptViewport()
    _ = vp.resolve(flatCount: 100, contentRows: 20)

    vp.queueScroll(by: -5)
    vp.queueScroll(by: -3)
    vp.queueScroll(by: -2)
    let first = vp.resolve(flatCount: 100, contentRows: 20)
    #expect(first == 70)
  }

  @Test func zeroContentRowsReturnsFlatCount() {
    var vp = TranscriptViewport()

    let first = vp.resolve(flatCount: 100, contentRows: 0)
    #expect(first == 100)
  }
}
