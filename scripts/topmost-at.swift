// Prints the owner of the frontmost on screen window under a screen point (top left origin), so
// scripts/device-qa.sh never clicks through to another app's window, a system prompt included.
// Usage: swift scripts/topmost-at.swift <x> <y>
import CoreGraphics
import Foundation

let v = CommandLine.arguments.dropFirst().compactMap { Double($0) }
guard v.count == 2 else { exit(2) }
let p = CGPoint(x: v[0], y: v[1])
// Front to back. Layer 25 and up is the menu bar, Dock and similar system chrome.
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
for w in list {
    let layer = w[kCGWindowLayer as String] as? Int ?? 0
    let alpha = w[kCGWindowAlpha as String] as? Double ?? 1
    guard alpha > 0, layer >= 0,
          let b = w[kCGWindowBounds as String] as? [String: Any],
          let rect = CGRect(dictionaryRepresentation: b as CFDictionary), rect.contains(p) else { continue }
    print((w[kCGWindowOwnerName as String] as? String ?? "?") + " " + String(layer))
    exit(0)
}
print("none")
