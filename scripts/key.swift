// Posts keyboard events to one process only, with CGEvent.postToPid, so
// nothing leaks to other apps. Never uses System Events or the global tap.
// Usage: swift scripts/key.swift <pid> key <name> [cmd] [shift] [ctrl] [alt]
//        swift scripts/key.swift <pid> type <text>
import CoreGraphics
import Foundation

let codes: [String: CGKeyCode] = [
    "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12,
    "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23,
    "9": 25, "7": 26, "8": 28, "0": 29, "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40,
    "n": 45, "m": 46, "return": 36, "tab": 48, "space": 49, "delete": 51, "escape": 53, "left": 123,
    "right": 124, "down": 125, "up": 126, "f5": 96, ".": 47, "/": 44, "-": 27, "=": 24, "[": 33, "]": 30,
]

let args = CommandLine.arguments
guard args.count >= 4, let pid = pid_t(args[1]) else {
    FileHandle.standardError.write(Data("usage: key.swift <pid> key <name> [mods] | type <text>\n".utf8))
    exit(2)
}

func post(_ code: CGKeyCode, flags: CGEventFlags, chars: String? = nil) {
    for down in [true, false] {
        guard let ev = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down) else { continue }
        ev.flags = flags
        if let chars {
            var units = Array(chars.utf16)
            ev.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
        }
        ev.postToPid(pid)
        usleep(15_000)
    }
}

switch args[2] {
case "key":
    var flags: CGEventFlags = []
    for m in args.dropFirst(4) {
        switch m {
        case "cmd": flags.insert(.maskCommand)
        case "shift": flags.insert(.maskShift)
        case "ctrl": flags.insert(.maskControl)
        case "alt": flags.insert(.maskAlternate)
        default: break
        }
    }
    guard let code = codes[args[3].lowercased()] else {
        FileHandle.standardError.write(Data("unknown key \(args[3])\n".utf8))
        exit(2)
    }
    post(code, flags: flags)
    print("posted \(args[3]) \(args.dropFirst(4).joined(separator: "+")) to pid \(pid)")
case "type":
    let text = args[3...].joined(separator: " ")
    for ch in text {
        let s = String(ch)
        post(codes[s.lowercased()] ?? 0, flags: [], chars: s)
    }
    print("typed \(text.count) chars to pid \(pid)")
default:
    exit(2)
}
