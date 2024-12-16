import Testing

import Scribe
@testable import MyScribe

@Test func testOne() async throws {
    let scribe = MyScribe()
    #expect(scribe.config.hello == "Hello My Name Is Scribe")
}
