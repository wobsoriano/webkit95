// A left click, right click, double click or left drag at screen points (top left origin, like
// accessibility frames), posted at the HID level with human pauses between the steps. Only
// scripts/device-qa.sh uses it, after checking that webkit95 is frontmost and the points lie
// inside its window.
// Usage: swift scripts/click.swift click <x> <y>
//        swift scripts/click.swift right <x> <y>
//        swift scripts/click.swift double <x> <y>
//        swift scripts/click.swift drag <x1> <y1> <x2> <y2>
import CoreGraphics
import Foundation

let args = CommandLine.arguments
let n = args.dropFirst(2).compactMap { Double($0) }
guard args.count >= 3, (["click", "right", "double"].contains(args[1]) && n.count == 2) || (args[1] == "drag" && n.count == 4) else {
    FileHandle.standardError.write(Data("usage: click.swift click x y | right x y | double x y | drag x1 y1 x2 y2\n".utf8))
    exit(2)
}

func post(_ type: CGEventType, _ p: CGPoint, clicks: Int64 = 1, button: CGMouseButton = .left) {
    let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: p, mouseButton: button)
    event?.setIntegerValueField(.mouseEventClickState, value: clicks)
    event?.post(tap: .cghidEventTap)
}

let from = CGPoint(x: n[0], y: n[1])
post(.mouseMoved, from)
usleep(80_000)
switch args[1] {
case "right":
    post(.rightMouseDown, from, button: .right)
    usleep(120_000)
    post(.rightMouseUp, from, button: .right)
case "drag":
    post(.leftMouseDown, from)
    usleep(120_000)
    let to = CGPoint(x: n[2], y: n[3])
    for i in 1...24 {
        let t = CGFloat(i) / 24
        post(.leftMouseDragged, CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t))
        usleep(25_000)
    }
    usleep(150_000)
    post(.leftMouseUp, to)
default:
    post(.leftMouseDown, from)
    usleep(120_000)
    post(.leftMouseUp, from)
    if args[1] == "double" {
        usleep(80_000)
        post(.leftMouseDown, from, clicks: 2)
        usleep(60_000)
        post(.leftMouseUp, from, clicks: 2)
    }
}
print("\(args[1]) done")
