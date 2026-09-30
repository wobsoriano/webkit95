// Prints how many on screen windows of the named app sit above the normal window layer (menus,
// popovers). Usage: swift scripts/popup-windows.swift [owner, default webkit95]
import CoreGraphics
import Foundation

let owner = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "webkit95"
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
print(list.filter { ($0[kCGWindowOwnerName as String] as? String) == owner && ($0[kCGWindowLayer as String] as? Int ?? 0) > 0 }.count)
