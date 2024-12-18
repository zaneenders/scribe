import _NIOFileSystem

// Very rough outline of what a program protocol might be like.
/*
What are the common ways to interact with any ``Program``?
- up, down, left, right, in (open), out, (close), ...
*/
protocol Program {
    mutating func up(_ num: Int)
    mutating func down(_ num: Int)
    mutating func open() async throws -> OpenResult
    mutating func close() async throws
}

extension Program {
    mutating func up() {
        up(1)
    }
    mutating func down() {
        down(1)
    }
}

enum OpenResult {
    case dir
    case file(cwd: FilePath, file: FilePath)
}
