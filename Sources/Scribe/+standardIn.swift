import SystemPackage

/// Hoping I won't need this extension with later versions of Foundation that
/// support for API's on linux
extension FileDescriptor {

    /// Return an iterator over the bytes in the file.
    ///
    /// - returns: An iterator for UInt8 elements.
    public func asyncByteIterator() -> _FileHandleAsyncByteIterator {
        _FileHandleAsyncByteIterator(fileHandle: self)
    }

    public struct _FileHandleAsyncByteIterator: AsyncSequence {

        public typealias Element = UInt8

        let fileHandle: FileDescriptor

        init(fileHandle: FileDescriptor) {
            self.fileHandle = fileHandle
        }

        public struct AsyncIterator: AsyncIteratorProtocol {
            public typealias Element = UInt8
            let fileHandle: FileDescriptor

            @available(*, deprecated, message: "Really bad, but works for now")
            public mutating func next() async throws -> UInt8? {
                let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: 1, alignment: 0)
                _ = try FileDescriptor.standardInput.read(into: buffer)
                let copy: [UInt8] = Array(buffer[0..<1])
                buffer.deallocate()
                return copy.first
            }
        }

        public func makeAsyncIterator() -> AsyncIterator {
            AsyncIterator(fileHandle: fileHandle)
        }
    }
}
