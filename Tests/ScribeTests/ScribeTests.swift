import Foundation
import Testing
import _NIOFileSystem

@testable import MyScribe
@testable import Scribe

@Test func testOne() async throws {
    let scribe = MyScribe()
    #expect(scribe.config.hello == "Hello My Name Is Scribe")
}

/*
Test that we can produce a window of the requested size
*/
@Test func fileSystemMovement() async throws {
    var system_view = try await SystemView(FilePath(FileManager.default.currentDirectoryPath))
    try await system_view.close()
    let tiles = system_view.tiles(80, 24)
    // Should not crash when rendering
    #expect(tiles[0].count == 80)
    #expect(tiles.count == 24)
}

/*
Test scrolling of a list of files in a directory when the list of files is longer than the window
size.
*/
@Test func getDirsInRange() async throws {
    var system_view = try await SystemView(FilePath(FileManager.default.currentDirectoryPath))
    system_view.down(5)
    var files = system_view.getDirsInRange(3).compactMap { entry in
        entry.path.lastComponent
    }
    var file_names: [String] {
        system_view.dirs.compactMap { entry in
            entry.path.lastComponent
        }.map { $0.string }
    }
    #expect(system_view.index == 5)
    #expect(file_names[system_view.index] == "Package.resolved")
    #expect(files == ["Package.resolved", "Package.swift", "README.md"])
    system_view.down()
    files = system_view.getDirsInRange(3).compactMap { entry in
        entry.path.lastComponent
    }
    print(file_names)
    #expect(file_names[system_view.index] == "Package.swift")
    #expect(system_view.index == 6)
    #expect(files == ["Package.swift", "README.md", "Sources"])
}
