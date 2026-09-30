// Captures every on screen window of one app (the main window plus popovers and other child
// windows) into one PNG, composited at their screen positions, with nothing from other apps.
// screencapture -l takes a single window, which misses a popover.
// Usage: swift scripts/capture.swift <out.png> [owner name, default webkit95]
import AppKit
import ScreenCaptureKit

let args = CommandLine.arguments
guard args.count >= 2 else {
    FileHandle.standardError.write(Data("usage: capture.swift out.png [owner]\n".utf8))
    exit(2)
}
let owner = args.count > 2 ? args[2] : "webkit95"

let done = DispatchSemaphore(value: 0)
Task {
    defer { done.signal() }
    do {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        let windows = content.windows.filter { $0.owningApplication?.applicationName == owner && $0.isOnScreen && $0.frame.width > 1 }
        guard let first = windows.first else {
            FileHandle.standardError.write(Data("no \(owner) window on screen\n".utf8))
            exit(1)
        }
        let union = windows.dropFirst().reduce(first.frame) { $0.union($1.frame) }
        guard let display = content.displays.first(where: { $0.frame.intersects(union) }) ?? content.displays.first else { exit(1) }
        let filter = SCContentFilter(display: display, including: windows)
        let config = SCStreamConfiguration()
        let scale = CGFloat(filter.pointPixelScale)
        config.sourceRect = CGRect(x: union.minX - display.frame.minX, y: union.minY - display.frame.minY, width: union.width, height: union.height)
        config.width = Int(union.width * scale)
        config.height = Int(union.height * scale)
        config.showsCursor = false
        config.backgroundColor = .clear
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        let rep = NSBitmapImageRep(cgImage: image)
        try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[1]))
        print(args[1])
    } catch {
        FileHandle.standardError.write(Data("capture failed: \(error)\n".utf8))
        exit(1)
    }
}
done.wait()
