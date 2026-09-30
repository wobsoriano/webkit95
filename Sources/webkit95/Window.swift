import AppKit
import Webkit95Kit

/// A borderless window, so macOS draws no rounded corners, shadow or title bar; the Win95 frame
/// and title bar are views inside it and drive AppKit's move, resize, zoom, minimize and close.
final class Win95Window: NSWindow {
    private var restoreFrame: NSRect?
    var onStateChange: (() -> Void)?

    init(contentRect: NSRect) {
        super.init(contentRect: contentRect, styleMask: [.borderless, .resizable, .miniaturizable, .closable], backing: .buffered, defer: false)
        hasShadow = false
        isOpaque = true
        backgroundColor = Win95Color.silver.ns
        isReleasedWhenClosed = false
        minSize = NSSize(width: 320, height: 200)
        acceptsMouseMovedEvents = true
        collectionBehavior = [.fullScreenNone, .managed]
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    var isMaximized: Bool { restoreFrame != nil }

    func toggleMaximize() {
        if let restoreFrame {
            self.restoreFrame = nil
            setFrame(restoreFrame, display: true, animate: false)
        } else if let visible = screen?.visibleFrame {
            restoreFrame = frame
            setFrame(visible, display: true, animate: false)
        }
        onStateChange?()
    }

    /// performClose without a title bar close button: asks the delegate, then closes.
    func win95Close() {
        if let delegate, delegate.windowShouldClose?(self) == false { return }
        close()
    }

    override func performClose(_ sender: Any?) { win95Close() }
    override func performMiniaturize(_ sender: Any?) { miniaturize(sender) }
    override func performZoom(_ sender: Any?) { toggleMaximize() }

    /// Resizing by a frame edge or the size grip. `edges` says which sides follow the mouse.
    func trackResize(_ event: NSEvent, edges: NSRectEdge.Set) {
        let start = NSEvent.mouseLocation
        let startFrame = frame
        restoreFrame = nil
        while let next = nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            let now = NSEvent.mouseLocation
            let dx = round(now.x - start.x), dy = round(now.y - start.y)
            var f = startFrame
            if edges.contains(.maxX) { f.size.width = max(startFrame.width + dx, minSize.width) }
            if edges.contains(.minX) {
                f.size.width = max(startFrame.width - dx, minSize.width)
                f.origin.x = startFrame.maxX - f.width
            }
            // Screen coordinates: the window's top edge is maxY.
            if edges.contains(.maxY) { f.size.height = max(startFrame.height + dy, minSize.height) }
            if edges.contains(.minY) {
                f.size.height = max(startFrame.height - dy, minSize.height)
                f.origin.y = startFrame.maxY - f.height
            }
            setFrame(f, display: true)
            if next.type == .leftMouseUp { break }
        }
        onStateChange?()
    }
}

extension NSRectEdge {
    struct Set: OptionSet {
        let rawValue: Int
        static let minX = Set(rawValue: 1)
        static let maxX = Set(rawValue: 2)
        static let minY = Set(rawValue: 4)
        static let maxY = Set(rawValue: 8)
    }
}

/// The window's content view: the 4 px sizing frame, the title bar, the content area, and the
/// menu and dialog layers on top of everything.
final class WindowFrameView: FaceView {
    static let border: CGFloat = 4
    let titleBar = TitleBarView()
    let content = FaceView()
    let menuLayer = MenuLayer()
    let dialogLayer = DialogLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(titleBar)
        addSubview(content)
        addSubview(menuLayer)
        addSubview(dialogLayer)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let b = Self.border
        titleBar.frame = NSRect(x: b, y: b, width: bounds.width - 2 * b, height: TitleBarView.height)
        content.frame = NSRect(x: b, y: b + TitleBarView.height + 1, width: bounds.width - 2 * b, height: bounds.height - 2 * b - TitleBarView.height - 1)
        menuLayer.frame = bounds
        dialogLayer.frame = bounds
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        Draw.bevel(.windowFrame, bounds)
    }

    private func edges(at p: NSPoint) -> NSRectEdge.Set {
        let grab: CGFloat = Self.border
        let corner: CGFloat = 16
        var e: NSRectEdge.Set = []
        let left = p.x < grab || (p.x < corner && (p.y < grab || p.y > bounds.height - grab))
        let right = p.x > bounds.width - grab || (p.x > bounds.width - corner && (p.y < grab || p.y > bounds.height - grab))
        let top = p.y < grab || (p.y < corner && (p.x < grab || p.x > bounds.width - grab))
        let bottom = p.y > bounds.height - grab || (p.y > bounds.height - corner && (p.x < grab || p.x > bounds.width - grab))
        if left { e.insert(.minX) }
        if right { e.insert(.maxX) }
        if top { e.insert(.maxY) }
        if bottom { e.insert(.minY) }
        return e
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let e = edges(at: p)
        if !e.isEmpty, let window = window as? Win95Window { window.trackResize(event, edges: e) }
    }

    override func resetCursorRects() {
        let b = Self.border, c: CGFloat = 16
        let w = bounds.width, h = bounds.height
        addCursorRect(NSRect(x: c, y: 0, width: w - 2 * c, height: b), cursor: .resizeUpDown)
        addCursorRect(NSRect(x: c, y: h - b, width: w - 2 * c, height: b), cursor: .resizeUpDown)
        addCursorRect(NSRect(x: 0, y: c, width: b, height: h - 2 * c), cursor: .resizeLeftRight)
        addCursorRect(NSRect(x: w - b, y: c, width: b, height: h - 2 * c), cursor: .resizeLeftRight)
        if #available(macOS 15, *) {
            addCursorRect(NSRect(x: 0, y: 0, width: c, height: b), cursor: .frameResize(position: .topLeft, directions: .all))
            addCursorRect(NSRect(x: 0, y: 0, width: b, height: c), cursor: .frameResize(position: .topLeft, directions: .all))
            addCursorRect(NSRect(x: w - c, y: 0, width: c, height: b), cursor: .frameResize(position: .topRight, directions: .all))
            addCursorRect(NSRect(x: w - b, y: 0, width: b, height: c), cursor: .frameResize(position: .topRight, directions: .all))
            addCursorRect(NSRect(x: 0, y: h - b, width: c, height: b), cursor: .frameResize(position: .bottomLeft, directions: .all))
            addCursorRect(NSRect(x: 0, y: h - c, width: b, height: c), cursor: .frameResize(position: .bottomLeft, directions: .all))
            addCursorRect(NSRect(x: w - c, y: h - b, width: c, height: b), cursor: .frameResize(position: .bottomRight, directions: .all))
            addCursorRect(NSRect(x: w - b, y: h - c, width: b, height: c), cursor: .frameResize(position: .bottomRight, directions: .all))
        }
    }
}

/// Navy (or gray when inactive) title bar with the app icon, a bold title and the three buttons.
final class TitleBarView: FaceView {
    static let height: CGFloat = 18
    var title = "" { didSet { if oldValue != title { needsDisplay = true; setAccessibilityLabel(title) } } }
    var isActive = true { didSet { if oldValue != isActive { needsDisplay = true } } }
    var icon: Icon? = .app16 { didSet { needsDisplay = true } }
    var showsMinMax = true { didSet { needsLayout = true } }
    let minimize = Win95Button("", style: .titleBar, icon: .minimize)
    let maximize = Win95Button("", style: .titleBar, icon: .maximize)
    let close = Win95Button("", style: .titleBar, icon: .close)
    var onClose: (() -> Void)?
    /// Set for dialog title bars: drags move the dialog inside the window instead of the window.
    var onDrag: ((NSEvent) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        for (b, name) in [(minimize, "Minimize"), (maximize, "Maximize"), (close, "Close")] {
            addSubview(b)
            b.setAccessibilityLabel(name)
        }
        minimize.action = { [weak self] in self?.window?.miniaturize(nil) }
        maximize.action = { [weak self] in (self?.window as? Win95Window)?.toggleMaximize() }
        close.action = { [weak self] in
            guard let self else { return }
            if let onClose = self.onClose { onClose() } else { (self.window as? Win95Window)?.win95Close() }
        }
        setAccessibilityRole(.group)
        setAccessibilityIdentifier("titlebar")
    }

    required init?(coder: NSCoder) { fatalError() }

    func syncMaximizeGlyph() {
        maximize.icon = (window as? Win95Window)?.isMaximized == true ? .restore : .maximize
    }

    override func layout() {
        super.layout()
        let y: CGFloat = 2
        close.frame = NSRect(x: bounds.width - 2 - 16, y: y, width: 16, height: 14)
        maximize.frame = NSRect(x: close.frame.minX - 2 - 16, y: y, width: 16, height: 14)
        minimize.frame = NSRect(x: maximize.frame.minX - 16, y: y, width: 16, height: 14)
        minimize.isHidden = !showsMinMax
        maximize.isHidden = !showsMinMax
    }

    override func draw(_ dirtyRect: NSRect) {
        Draw.crisp()
        Draw.fill(bounds, isActive ? .navy : .gray)
        var x: CGFloat = 2
        if let icon {
            PixelImages.draw(icon, at: NSPoint(x: x, y: 1))
            x += 18
        }
        let limit = (showsMinMax ? minimize.frame.minX : close.frame.minX) - 4 - x
        Draw.text(Self.truncate(title, width: limit), at: NSPoint(x: x, y: 1), color: isActive ? .white : .silver, bold: true)
    }

    static func truncate(_ text: String, width: CGFloat, bold: Bool = true) -> String {
        if Draw.width(text, bold: bold) <= width { return text }
        var s = text
        while !s.isEmpty && Draw.width(s + "...", bold: bold) > width { s.removeLast() }
        return s + "..."
    }

    override func mouseDown(with event: NSEvent) {
        if let onDrag {
            onDrag(event)
            return
        }
        if event.clickCount == 2, showsMinMax {
            (window as? Win95Window)?.toggleMaximize()
            return
        }
        window?.performDrag(with: event)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
