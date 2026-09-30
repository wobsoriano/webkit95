// Accessibility reads and presses on webkit95's window, without the keyboard, the mouse or
// activating the app. Exits 3 when this process lacks the Accessibility permission.
// Usage: swift scripts/ax.swift <pid> <identifier>     value of the first element with that id
//        swift scripts/ax.swift <pid> field <identifier> JSON: role, focused, value, selection
//        swift scripts/ax.swift <pid> press <label>      AXPress the first element with that
//                                                         description or title (a button)
//        swift scripts/ax.swift <pid> menu <menu> <item> AXPress a menu bar item
//        swift scripts/ax.swift <pid> menu-items <menu>  "title<TAB>enabled|disabled" per item of a
//                                                         menu bar menu, read only
//        swift scripts/ax.swift <pid> frame <label>      "x y width height" of the first element
//                                                         with that description, title or id
//        swift scripts/ax.swift <pid> open-menu          titles of the items of an open context
//                                                         menu, one per line
//        swift scripts/ax.swift <pid> tabs               the strip's tabs left to right, one
//                                                         "x y width height label" line each
//                                                         (screen points, tab separated)
import ApplicationServices
import Foundation

let args = CommandLine.arguments
guard args.count >= 3, let pid = pid_t(args[1]) else {
    FileHandle.standardError.write(Data("usage: ax.swift <pid> <identifier> | field <id> | press <label> | menu <menu> <item> | tabs\n".utf8))
    exit(2)
}
guard AXIsProcessTrusted() else {
    FileHandle.standardError.write(Data("no accessibility permission for this terminal\n".utf8))
    exit(3)
}

let app = AXUIElementCreateApplication(pid)

func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
    var value: AnyObject?
    return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
}

func children(_ element: AXUIElement) -> [AXUIElement] {
    attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
}

func find(_ element: AXUIElement, depth: Int = 0, _ match: (AXUIElement) -> Bool) -> AXUIElement? {
    if match(element) { return element }
    guard depth < 40 else { return nil }
    for child in children(element) {
        if let hit = find(child, depth: depth + 1, match) { return hit }
    }
    return nil
}

func all(_ element: AXUIElement, depth: Int = 0, _ match: (AXUIElement) -> Bool) -> [AXUIElement] {
    let here = match(element) ? [element] : []
    guard depth < 40 else { return here }
    return here + children(element).flatMap { all($0, depth: depth + 1, match) }
}

func string(_ element: AXUIElement, _ name: String) -> String? { attribute(element, name) as? String }

func windows() -> [AXUIElement] { attribute(app, kAXWindowsAttribute) as? [AXUIElement] ?? [] }

func byIdentifier(_ id: String) -> AXUIElement? {
    windows().lazy.compactMap { find($0) { string($0, kAXIdentifierAttribute) == id } }.first
}

func json(_ object: [String: Any]) {
    let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
    print(String(decoding: data, as: UTF8.self))
}

func press(_ element: AXUIElement) {
    let rc = AXUIElementPerformAction(element, kAXPressAction as CFString)
    print(rc == .success ? "pressed" : "press failed \(rc.rawValue)")
    exit(rc == .success ? 0 : 1)
}

switch args[2] {
case "field":
    guard args.count == 4, let hit = byIdentifier(args[3]) else {
        print("absent")
        exit(1)
    }
    var selection: [Int] = []
    if let raw = attribute(hit, kAXSelectedTextRangeAttribute), CFGetTypeID(raw) == AXValueGetTypeID() {
        var range = CFRange()
        if AXValueGetValue(raw as! AXValue, .cfRange, &range) { selection = [range.location, range.length] }
    }
    json([
        "role": string(hit, kAXRoleAttribute) ?? "",
        "focused": (attribute(hit, kAXFocusedAttribute) as? Bool) ?? false,
        "value": string(hit, kAXValueAttribute) ?? "",
        "selection": selection,
    ])
case "press":
    guard args.count == 4 else { exit(2) }
    let label = args[3]
    guard let hit = windows().lazy.compactMap({
        find($0) { string($0, kAXDescriptionAttribute) == label || string($0, kAXTitleAttribute) == label }
    }).first else {
        print("absent")
        exit(1)
    }
    press(hit)
case "menu":
    guard args.count == 5, let bar = attribute(app, kAXMenuBarAttribute) else { exit(2) }
    let menu = children(bar as! AXUIElement).first { string($0, kAXTitleAttribute) == args[3] }
    let item = menu.flatMap { find($0) { string($0, kAXRoleAttribute) == kAXMenuItemRole && string($0, kAXTitleAttribute) == args[4] } }
    guard let item else {
        print("absent")
        exit(1)
    }
    press(item)
case "menu-items":
    // Reads a menu bar menu's items without opening or pressing anything.
    guard args.count == 4, let bar = attribute(app, kAXMenuBarAttribute) else { exit(2) }
    let menu = children(bar as! AXUIElement).first { string($0, kAXTitleAttribute) == args[3] }
    for item in menu.map({ all($0) { string($0, kAXRoleAttribute) == kAXMenuItemRole } }) ?? [] {
        guard let title = string(item, kAXTitleAttribute), !title.isEmpty else { continue }
        print("\(title)\t\((attribute(item, kAXEnabledAttribute) as? Bool) == true ? "enabled" : "disabled")")
    }
case "frame":
    guard args.count == 4 else { exit(2) }
    let label = args[3]
    guard let hit = windows().lazy.compactMap({ find($0) {
        string($0, kAXDescriptionAttribute) == label || string($0, kAXTitleAttribute) == label || string($0, kAXIdentifierAttribute) == label
    } }).first else {
        print("absent")
        exit(1)
    }
    var point = CGPoint.zero
    var size = CGSize.zero
    if let raw = attribute(hit, kAXPositionAttribute) { AXValueGetValue(raw as! AXValue, .cgPoint, &point) }
    if let raw = attribute(hit, kAXSizeAttribute) { AXValueGetValue(raw as! AXValue, .cgSize, &size) }
    print("\(Int(point.x)) \(Int(point.y)) \(Int(size.width)) \(Int(size.height))")
case "open-menu":
    // Only a context menu's own items: the menu bar and every submenu (Services, Recent Items and
    // the like, which list the user's files) are never entered.
    func contextMenus(_ el: AXUIElement, depth: Int = 0) -> [AXUIElement] {
        let role = string(el, kAXRoleAttribute)
        if role == kAXMenuBarRole || role == kAXMenuItemRole || depth > 12 { return [] }
        if role == kAXMenuRole { return [el] }
        return children(el).flatMap { contextMenus($0, depth: depth + 1) }
    }
    for menu in contextMenus(app) {
        for item in children(menu) where string(item, kAXRoleAttribute) == kAXMenuItemRole {
            if let title = string(item, kAXTitleAttribute), !title.isEmpty { print(title) }
        }
    }
case "tabs":
    // Tab items carry the "Pin" or "Unpin" named action, which nothing else in the window has.
    let tabs = windows().flatMap { all($0) { el in
        var names: CFArray?
        AXUIElementCopyActionNames(el, &names)
        return (names as? [String] ?? []).contains { $0.contains("Pin") || $0.contains("Unpin") }
    } }
    let rows = tabs.map { el -> (CGPoint, CGSize, String) in
        var point = CGPoint.zero
        var size = CGSize.zero
        if let raw = attribute(el, kAXPositionAttribute) { AXValueGetValue(raw as! AXValue, .cgPoint, &point) }
        if let raw = attribute(el, kAXSizeAttribute) { AXValueGetValue(raw as! AXValue, .cgSize, &size) }
        return (point, size, string(el, kAXDescriptionAttribute) ?? string(el, kAXTitleAttribute) ?? "")
    }.sorted { $0.0.x < $1.0.x }
    for (p, s, label) in rows { print("\(Int(p.x))\t\(Int(p.y))\t\(Int(s.width))\t\(Int(s.height))\t\(label)") }
default:
    guard let hit = byIdentifier(args[2]) else {
        print("absent")
        exit(1)
    }
    print(string(hit, kAXValueAttribute) ?? string(hit, kAXDescriptionAttribute) ?? "")
}
