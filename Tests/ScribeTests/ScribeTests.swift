import Foundation
import Testing
import _NIOFileSystem

@testable import MyScribe
@testable import Scribe

@Test func testOne() async throws {
    let scribe = MyScribe()
    #expect(scribe.config.hello == "Hello My Name Is Scribe")
}

@Test func fileSystemMovement() async throws {
    var system_view = try await SystemView(FilePath(FileManager.default.currentDirectoryPath))
    try await system_view.close()
    let tiles = system_view.tiles(80, 24)
    // Should not crash when rendering
    #expect(tiles[0].count == 80)
    #expect(tiles.count == 24)
}
