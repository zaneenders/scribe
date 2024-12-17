//
//  AsciiKeyCode.swift
//
//
//  Created by Zane Enders on 5/21/22.
//

/// Ascii Key Codes
enum AsciiKeyCode: UInt8, Sendable {
    /// Returns an Optional AsciiKeyCode form an Optional Int
    static func decode(keyboard code: consuming UInt8?) -> AsciiKeyCode? {
        guard let unwrappedCode = code else {
            return nil
        }
        System.Log.trace("\(unwrappedCode)")
        return AsciiKeyCode(rawValue: unwrappedCode)
    }

    case ctrlSpace = 0x00
    case ctrlA = 0x01  // Cannot Read from Terminal
    case ctrlB = 0x02
    case ctrlC = 0x03
    case ctrlD = 0x04
    case ctrlE = 0x05
    case ctrlF = 0x06
    case ctrlG = 0x07
    case ctrlH = 0x08
    case ctrlI = 0x09  // Tab
    case ctrlJ = 0x0A
    case ctrlK = 0x0B
    case ctrlL = 0x0C
    case ctrlM = 0x0D
    case ctrlN = 0x0E
    case ctrlO = 0x0F
    case ctrlP = 0x10
    case ctrlQ = 0x11  // Cannot Read from Terminal
    case ctrlR = 0x12
    case ctrlS = 0x13  // Cannot Read from Terminal
    case ctrlT = 0x14
    case ctrlU = 0x15
    case ctrlV = 0x16
    case ctrlW = 0x17
    case ctrlX = 0x18
    case ctrlY = 0x19
    case space = 0x20  // 32 lol
    case ctrlZ = 0x1A
    case esc = 0x1B
    case delete = 0x7F
    case tilda = 0x7E
    //    use terminal flags "stty -ixon" to enable?
    //???: How should we handle Shift commands?
    //    case [ = 0x5B // shift Tab
    //    case Z = 0x5A
    case one = 0x31
    case two = 0x32
    case three = 0x33
    case four = 0x34
    case five = 0x35
    case six = 0x36
    case seven = 0x37
    case eight = 0x38
    case nine = 0x39
    case zero = 0x30
    case minus = 0x2D
    case equal = 0x3D
    case bang = 0x21
    case at = 0x40
    case pound = 0x23
    case dollarSign = 0x24
    case percent = 0x25
    case caret = 0x5E
    case and = 0x26
    case asterisk = 0x2A
    case openParentheses = 0x28
    case closingParentheses = 0x29
    case underscore = 0x5F
    case plus = 0x2B
    case lowercaseQ = 0x71
    case lowercaseW = 0x77
    case lowercaseE = 0x65
    case lowercaseR = 0x72
    case lowercaseT = 0x74
    case lowercaseY = 0x79
    case lowercaseU = 0x75
    case lowercaseI = 0x69
    case lowercaseO = 0x6F
    case lowercaseP = 0x70
    case openBracket = 0x5B
    case closingBracket = 0x5D
    case backslash = 0x5C
    case upperCaseQ = 0x51
    case upperCaseW = 0x57
    case upperCaseE = 0x45
    case upperCaseR = 0x52
    case upperCaseT = 0x54
    case upperCaseY = 0x59
    case upperCaseU = 0x55
    case upperCaseI = 0x49
    case upperCaseO = 0x4F
    case upperCaseP = 0x50
    case openCurlyBrace = 0x7B
    case closedCurlyBrace = 0x7D
    case pipe = 0x7C
    case lowerCaseA = 0x61
    case lowerCaseS = 0x73
    case lowerCaseD = 0x64
    case lowerCaseF = 0x66
    case lowerCaseG = 0x67
    case lowerCaseH = 0x68
    case lowerCaseJ = 0x6A
    case lowerCaseK = 0x6B
    case lowerCaseL = 0x6C
    case semicolon = 0x3B
    case apostrophe = 0x27
    case upperCaseA = 0x41
    case upperCaseS = 0x53
    case upperCaseD = 0x44
    case upperCaseF = 0x46
    case upperCaseG = 0x47
    case upperCaseH = 0x48
    case upperCaseJ = 0x4A
    case upperCaseK = 0x4B
    case upperCaseL = 0x4C
    case colon = 0x3A
    case quotationMark = 0x22
    case lowerCaseZ = 0x7A
    case lowerCaseX = 0x78
    case lowerCaseC = 0x63
    case lowerCaseV = 0x76
    case lowerCaseB = 0x62
    case lowerCaseN = 0x6E
    case lowerCaseM = 0x6D
    case comma = 0x2C
    case period = 0x2E
    case forwardSlash = 0x2F
    case upperCaseZ = 0x5A
    case upperCaseX = 0x58
    case upperCaseC = 0x43
    case upperCaseV = 0x56
    case upperCaseB = 0x42
    case upperCaseN = 0x4E
    case upperCaseM = 0x4D
    case lessThen = 0x3C
    case greaterThen = 0x3E
    case questionMark = 0x3F
}
