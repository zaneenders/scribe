//
//  Terminal.swift
//
//
//  Created by Zane Enders on 2/19/22.
//

import SystemPackage

#if os(macOS)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

// MARK: none private API's
extension Terminal {

    static var size: TerminalSize {
        // TODO look into the SIGWINCH signal maybe replace this function or
        // its call sites.
        var w: winsize = Terminal.initCStruct()
        //???: Is it possible to get a call back or notification of when the window is resized
        _ = ioctl(STDOUT_FILENO, UInt(TIOCGWINSZ), &w)
        // Check that we have a valid window size
        // ???: Should this throw instead?
        if w.ws_row == 0 || w.ws_col == 0 {
            return TerminalSize(x: -1, y: -1)
        } else {
            return TerminalSize(
                x: Int(w.ws_col.magnitude), y: Int(w.ws_row.magnitude))
        }
    }

    /// Draws a ``TerminalViewable`` to the terminal screen using ``Window``.
    mutating func render<W: TerminalViewable>(_ viewable: borrowing W) where W: ~Copyable {
        let before = System.clock.now
        self.window.render(viewable)
        do {
            try draw()
        } catch {
            System.Log.error("\(#function): Unable to draw frame.")
        }
        let after = System.clock.now
        System.Log.trace("\(#function): \(before.duration(to: after))")
    }
}

struct TerminalSize: Hashable {
    let x: Int
    let y: Int
}

enum TerminalError: Error {
    case setupError  // Thrown if there is an error writing to standard out.
}

/// Sets up the Terminal to be in raw mode so we receive the key commands as
/// they are pressed.
struct Terminal: ~Copyable {
    private let prev: termios

    // interacted with through Terminal apis.
    private var window: Window

    init() throws {
        self.prev = Terminal.enableRawMode()
        do {
            try Terminal.setup()
        } catch {
            System.Log.error("Error setting up Terminal: restoring.")
            Terminal.restore(prev)
            throw TerminalError.setupError
        }
        let size = Terminal.size
        self.window = Window(size.x, size.y)
    }

    /// Restore the original terminal config
    /// Clear the last frame from the screen
    deinit {
        System.Log.trace("Terminal: deinit.")
        Terminal.restore(prev)
        do {
            try Terminal.reset()
        } catch {
            System.Log.error("Unable to reset terminal")
        }
    }

    private static func restore(_ originalConfig: termios) {
        var term = originalConfig
        // restores the original terminal state
        tcsetattr(FileDescriptor.standardInput.rawValue, TCSAFLUSH, &term)
        System.Log.trace("Terminal: restored.")
    }

    private static func enableRawMode() -> termios {
        // see https://stackoverflow.com/a/24335355/669586
        // init raw: termios variable
        var raw: termios = Terminal.initCStruct()
        // sets raw to a copy of the file handlers attributes
        tcgetattr(FileDescriptor.standardInput.rawValue, &raw)
        // saves a copy of the original standard output file descriptor to revert back to
        let originalConfig = raw
        // ??? is this fully correct?
        // sets magical bits to enable "raw mode"
        //https://code.woboq.org/userspace/glibc/sysdeps/unix/sysv/linux/bits/termios-c_lflag.h.html
        #if os(Linux)
        raw.c_lflag &= UInt32(~(UInt32(ECHO | ICANON | IEXTEN | ISIG)))
        #else  // MacOS
        raw.c_lflag &= UInt(~(UInt32(ECHO | ICANON | IEXTEN | ISIG)))
        #endif
        // changes the file descriptor to raw mode
        tcsetattr(FileDescriptor.standardInput.rawValue, TCSAFLUSH, &raw)
        System.Log.trace("Terminal: Raw Mode enabled.")
        return originalConfig
    }

    private static func initCStruct<S>() -> S {
        let structPointer = UnsafeMutablePointer<S>.allocate(capacity: 1)
        let structMemory = structPointer.pointee
        structPointer.deallocate()
        return structMemory
    }
}

extension Terminal {
    /*
    NOTE Don't use `print` as this adds funky spacing to the output behavior of
    the terminal.
    */

    /// Draws what ever is in the ``Window`` to the terminal using the
    /// ``Window/ascii``
    private func draw() throws {
        try Terminal.write(frame: self.window.ascii)
    }

    func goodbye() {
        System.Log.trace("Goodbye, 👋.")
    }

    /// Should be called at the beginning of the program to setup the screen state correctly.
    private static func setup() throws {
        _ = try setupCode.utf8CString.withUnsafeBytes { pointer in
            try FileDescriptor.standardOutput.write(pointer)
        }
    }

    /// Used to write the contents of of the frame to the screen.
    private static func write(frame strFrame: String) throws {
        try clear()
        _ = try strFrame.utf8CString.withUnsafeBytes { pointer in
            try FileDescriptor.standardOutput.write(pointer)
        }
    }

    /// clears the screen to setup, reset or write a new frame to the screen.
    private static func clear() throws {
        _ = try Terminal.clearCode.utf8CString.withUnsafeBytes { pointer in
            try FileDescriptor.standardOutput.write(pointer)
        }
    }

    /// Resets the terminal and cursor to the screen.
    private static func reset() throws {
        try clear()
        _ = try Terminal.restCode.utf8CString.withUnsafeBytes { pointer in
            try FileDescriptor.standardOutput.write(pointer)
        }
    }

    private static var restCode: String {
        AnsiEscapeCode.Cursor.show.rawValue
            + AnsiEscapeCode.Cursor.Style.Block.blinking.rawValue
            + AnsiEscapeCode.home.rawValue
    }

    private static var setupCode: String {
        AnsiEscapeCode.Cursor.hide.rawValue + clearCode
    }

    private static var clearCode: String {
        AnsiEscapeCode.eraseScreen.rawValue + AnsiEscapeCode.eraseSaved.rawValue
            + AnsiEscapeCode.home.rawValue
            + AnsiEscapeCode.Cursor.Style.Block.blinking.rawValue
    }

}
