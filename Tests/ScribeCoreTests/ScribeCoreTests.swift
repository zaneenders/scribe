import XCTest

@testable import ScribeCore

final class ScribeTests: XCTestCase {

    func testIn1() async {
        let start: SelectedStateNode = .selected(
            .group(
                .entire, .horizontal,
                [
                    .button("0", {})
                ]
            ))
        let r = start.apply(command: .in).0
        let expected: SelectedStateNode = .group(
            .index(0), .horizontal,
            [
                .selected(.button("0", {}))
            ]
        )
        XCTAssertEqual(expected, r)
    }

    func testOut1() async {
        let start: SelectedStateNode = .group(
            .index(0), .horizontal,
            [
                .selected(.button("0", {}))
            ]
        )
        let r = start.apply(command: .out).0
        let expected: SelectedStateNode = .selected(
            .group(
                .entire, .horizontal,
                [
                    .button("0", {})
                ]
            ))
        XCTAssertEqual(expected, r)
    }

    func testIn2() async {
        let start: SelectedStateNode = .group(
            .index(0), .horizontal,
            [
                .selected(
                    .group(
                        .entire, .horizontal,
                        [
                            .button("0", {})
                        ]
                    ))
            ])
        let r = start.apply(command: .in).0
        let expected: SelectedStateNode = .group(
            .index(0), .horizontal,
            [
                .group(
                    .index(0), .horizontal,
                    [
                        .selected(.button("0", {}))
                    ]
                )
            ])
        XCTAssertEqual(expected, r)
    }

    func testIn3() async {
        let start: SelectedStateNode = .selected(
            .group(
                .entire, .horizontal,
                [
                    .button("0", {})
                ]
            ))
        var r = start.apply(command: .in).0
        let expected: SelectedStateNode = .group(
            .index(0), .horizontal,
            [
                .selected(.button("0", {}))
            ]
        )
        r = start.apply(command: .in).0
        XCTAssertEqual(expected, r)
        r = start.apply(command: .in).0
        // Check that you can't move in past leaf nodes
        XCTAssertEqual(expected, r)
    }

    func testOut3() async {
        let start: SelectedStateNode = .group(
            .index(0), .horizontal,
            [
                .selected(.button("0", {}))
            ]
        )
        var r = start.apply(command: .out).0
        let expected: SelectedStateNode = .selected(
            .group(
                .entire, .horizontal,
                [
                    .button("0", {})
                ]
            ))
        XCTAssertEqual(expected, r)
        r = start.apply(command: .out).0
        XCTAssertEqual(expected, r)
        r = start.apply(command: .out).0
        // Check that you can't move out past last group
        XCTAssertEqual(expected, r)
    }

    func testSample1() async {
        // This test is pulled from .computeVisible before the switch statement
        let test: SelectedStateNode = .selected(
            .group(
                .entire, .horizontal,
                [
                    .group(
                        .entire, .vertical,
                        [
                            .button("0", {}),
                            .text(""),
                            .textEntry(EntryStorage("Place Holder")),
                        ])
                ]))
        var r = test.apply(command: .in).0
        var expected: SelectedStateNode = .group(
            .index(0), .horizontal,
            [
                .selected(
                    .group(
                        .entire, .vertical,
                        [
                            .button("0", {}),
                            .text(""),
                            .textEntry(EntryStorage("Place Holder")),
                        ]))
            ])
        XCTAssertEqual(expected, r)
        r = r.apply(command: .in).0
        expected = .group(
            .index(0), .horizontal,
            [
                .group(
                    .index(0), .vertical,
                    [
                        .selected(.button("0", {})),
                        .text(""),
                        .textEntry(EntryStorage("Place Holder")),
                    ])
            ])
        XCTAssertEqual(expected, r)
        r = r.apply(command: .down).0
        expected = .group(
            .index(0), .horizontal,
            [
                .group(
                    .index(1), .vertical,
                    [
                        .button("0", {}),
                        .selected(.text("")),
                        .textEntry(EntryStorage("Place Holder")),
                    ])
            ])
        XCTAssertEqual(expected, r)
        r = r.apply(command: .down).0
        expected = .group(
            .index(0), .horizontal,
            [
                .group(
                    .index(2), .vertical,
                    [
                        .button("0", {}),
                        .text(""),
                        .selected(.textEntry(EntryStorage("Place Holder"))),
                    ])
            ])
        XCTAssertEqual(expected, r)
        r = r.apply(command: .up).0
        expected = .group(
            .index(0), .horizontal,
            [
                .group(
                    .index(1), .vertical,
                    [
                        .button("0", {}),
                        .selected(.text("")),
                        .textEntry(EntryStorage("Place Holder")),
                    ])
            ])
        XCTAssertEqual(expected, r)
        r = r.apply(command: .out).0
        expected = .group(
            .index(0), .horizontal,
            [
                .selected(
                    .group(
                        .entire, .vertical,
                        [
                            .button("0", {}),
                            .text(""),
                            .textEntry(EntryStorage("Place Holder")),
                        ]))
            ])
        XCTAssertEqual(expected, r)
        r = r.apply(command: .out).0
        expected = .selected(
            .group(
                .entire, .horizontal,
                [
                    .group(
                        .entire, .vertical,
                        [
                            .button("0", {}),
                            .text(""),
                            .textEntry(EntryStorage("Place Holder")),
                        ])
                ]))
        XCTAssertEqual(expected, r)
        r = r.apply(command: .out).0
        expected = .selected(
            .group(
                .entire, .horizontal,
                [
                    .group(
                        .entire, .vertical,
                        [
                            .button("0", {}),
                            .text(""),
                            .textEntry(EntryStorage("Place Holder")),
                        ])
                ]))
        XCTAssertEqual(expected, r)
    }

    func testSample2() async {
        // This test is pulled from .computeVisible before the switch statement
        let test: SelectedStateNode = .selected(
            .group(
                .entire, .horizontal,
                [
                    .group(
                        .entire, .vertical,
                        [
                            .button("0", {}),
                            .text(""),
                            .textEntry(EntryStorage("Place Holder")),
                        ])
                ]))
        var r = test.apply(command: .down).0
        let expected: SelectedStateNode = .selected(
            .group(
                .entire, .horizontal,
                [
                    .group(
                        .entire, .vertical,
                        [
                            .button("0", {}),
                            .text(""),
                            .textEntry(EntryStorage("Place Holder")),
                        ])
                ]))
        XCTAssertEqual(expected, r)
        r = test.apply(command: .left).0
        XCTAssertEqual(expected, r)
        r = test.apply(command: .right).0
        XCTAssertEqual(expected, r)
    }
}
