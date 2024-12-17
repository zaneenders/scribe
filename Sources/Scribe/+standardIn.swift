import SystemPackage

/// Hoping I won't need this extension with later versions of Foundation that
/// support for API's on linux
extension FileDescriptor {

    /// Return an iterator over the bytes in the file.
    ///
    /// - returns: An iterator for UInt8 elements.
    func asyncByteIterator() -> _FileHandleAsyncByteIterator {
        _FileHandleAsyncByteIterator(fileDescriptor: self)
    }

    struct _FileHandleAsyncByteIterator: AsyncSequence {

        let fileDescriptor: FileDescriptor

        init(fileDescriptor: FileDescriptor) {
            self.fileDescriptor = fileDescriptor
        }

        struct AsyncIterator: AsyncIteratorProtocol {
            let fileDescriptor: FileDescriptor

            @available(*, deprecated, message: "Really bad, but works for now")
            mutating func next() async throws -> UInt8? {
                let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: 1, alignment: 0)
                _ = try FileDescriptor.standardInput.read(into: buffer)
                let copy: [UInt8] = Array(buffer[0..<1])
                buffer.deallocate()
                return copy.first
            }
        }

        func makeAsyncIterator() -> AsyncIterator {
            AsyncIterator(fileDescriptor: fileDescriptor)
        }
    }
}
