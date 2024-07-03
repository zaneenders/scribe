import ScribeCore
import XCTest

final class PublicScribeTests: XCTestCase {

    func testVisible1() async {
        let t: some Block = Group(.horizontal) {
            "Hello"
            " "
            "World"
        }
        let renderer = await Scribe(observing: t, width: 80, height: 24)
        await renderer.command(.out)
        let visible = await renderer.current
        let expected: VisibleNode = .selected(
            .group(
                .vertical,
                [
                    .group(
                        .horizontal,
                        [
                            .text("Hello"),
                            .text(" "),
                            .text("World"),
                        ])
                ]))
        XCTAssertEqual(visible, expected)
    }
}
