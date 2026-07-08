import Foundation

/// US ANSI virtual key codes plus the four modifier mask bits used by hotkeys.
public enum KeyCodes {
    public static let map: [String: Int] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7,
        "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15,
        "y": 16, "t": 17, "o": 31, "u": 32, "i": 34, "p": 35, "l": 37,
        "j": 38, "k": 40, "n": 45, "m": 46,
        "1": 18, "2": 19, "3": 20, "4": 21, "5": 23, "6": 22, "7": 26,
        "8": 28, "9": 25, "0": 29,
        "space": 49, "tab": 48, "return": 36, "escape": 53, "delete": 51,
        "forwarddelete": 117, "grave": 50, "minus": 27, "equal": 24,
        "leftbracket": 33, "rightbracket": 30, "backslash": 42,
        "semicolon": 41, "quote": 39, "comma": 43, "period": 47, "slash": 44,
        "left": 123, "right": 124, "down": 125, "up": 126,
        "home": 115, "end": 119, "pageup": 116, "pagedown": 121,
        "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97,
        "f7": 98, "f8": 100, "f9": 101, "f10": 109, "f11": 103, "f12": 111,
        "f13": 105, "f14": 107, "f15": 113, "f16": 106, "f17": 64,
        "f18": 79, "f19": 80,
    ]

    public static func code(for name: String) -> Int? {
        map[name.lowercased().trimmingCharacters(in: .whitespaces)]
    }
}

/// Modifier bit masks. Values match CGEventFlags so the agent can compare raw values.
public enum ModMask {
    public static let shift: UInt64 = 1 << 17
    public static let control: UInt64 = 1 << 18
    public static let option: UInt64 = 1 << 19
    public static let command: UInt64 = 1 << 20
    public static let relevant: UInt64 = shift | control | option | command

    public static func mask(from mods: [String]) -> UInt64 {
        mods.reduce(0) { acc, m in
            switch m.lowercased() {
            case "cmd", "command": return acc | command
            case "shift": return acc | shift
            case "opt", "option", "alt": return acc | option
            case "ctrl", "control": return acc | control
            default: return acc
            }
        }
    }
}
