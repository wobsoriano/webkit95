// Prints "<windowid> <title>" for on screen windows owned by the webkit95 process.
// Usage: swift scripts/winid.swift [owner name, default webkit95]
import CoreGraphics
import Foundation

let owner = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "webkit95"
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
for w in list {
    guard w[kCGWindowOwnerName as String] as? String == owner,
          let id = w[kCGWindowNumber as String] as? Int,
          (w[kCGWindowLayer as String] as? Int ?? 0) == 0 else { continue }
    let title = w[kCGWindowName as String] as? String ?? ""
    print("\(id) \(title)")
}
