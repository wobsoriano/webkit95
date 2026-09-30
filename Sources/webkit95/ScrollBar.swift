import AppKit
import Webkit95Kit

/// A Windows 95 scrollbar: two arrow buttons, a dithered track and a raised thumb. It knows
/// nothing about what it scrolls; the owner sets the geometry and handles `onScroll`.
final class Win95ScrollBar: FaceView {
    let vertical: Bool
    /// Total content length, visible length and offset, in points.
    var content: CGFloat = 0 { didSet { needsDisplay = true } }
    var visible: CGFloat = 0 { didSet { needsDisplay = true } }
    var offset: CGFloat = 0 { didSet { needsDisplay = true } }
    var line: CGFloat = 16
    var onScroll: ((CGFloat) -> Void)?

    private enum Part: Equatable { case decrement, increment, pageUp, pageDown, thumb }
    private var pressed: Part? { didSet { needsDisplay = true } }
    private var repeatTimer: Timer?

    static let thickness: CGFloat = 16

    init(vertical: Bool) {
        self.vertical = vertical
        super.init(frame: .zero)
        setAccessibilityRole(.scrollBar)
        setAccessibilityOrientation(vertical ? .vertical : .horizontal)
    }

    required init?(coder: NSCoder) { fatalError() }

    private var length: CGFloat { vertical ? bounds.height : bounds.width }
    private var maxOffset: CGFloat { max(content - visible, 0) }
    private var enabled: Bool { maxOffset > 0 && length > 2 * Self.thickness + 8 }
    private var trackStart: CGFloat { Self.thickness }
    private var trackLength: CGFloat { max(length - 2 * Self.thickness, 0) }

    private var thumbLength: CGFloat {
        guard content > 0 else { return trackLength }
        return max(min(floor(trackLength * visible / content), trackLength), 8)
    }

    private var thumbStart: CGFloat {
        guard maxOffset > 0 else { return trackStart }
        return trackStart + floor((trackLength - thumbLength) * min(offset, maxOffset) / maxOffset)
    }

    private func rect(along start: CGFloat, _ len: CGFloat) -> NSRect {
        vertical ? NSRect(x: 0, y: start, width: bounds.width, height: len)
                 : NSRect(x: start, y: 0, width: len, height: bounds.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        Draw.crisp()
        let track = rect(along: trackStart, trackLength)
        Draw.dither(track, .silver, .white)
        if pressed == .pageUp && enabled { Draw.fill(rect(along: trackStart, thumbStart - trackStart), .black) }
        if pressed == .pageDown && enabled {
            let end = thumbStart + thumbLength
            Draw.fill(rect(along: end, trackStart + trackLength - end), .black)
        }
        drawArrow(rect(along: 0, Self.thickness), icon: vertical ? .arrowUp : .arrowLeft, down: pressed == .decrement)
        drawArrow(rect(along: length - Self.thickness, Self.thickness), icon: vertical ? .arrowDown : .arrowRight, down: pressed == .increment)
        if enabled {
            let thumb = rect(along: thumbStart, thumbLength)
            Draw.fill(thumb, .silver)
            Draw.bevel(.raisedButton, thumb)
        }
    }

    private func drawArrow(_ r: NSRect, icon: Icon, down: Bool) {
        Draw.fill(r, .silver)
        if down {
            Draw.hline(r.minX, r.minY, r.width, .gray)
            Draw.hline(r.minX, r.maxY - 1, r.width, .gray)
            Draw.vline(r.minX, r.minY, r.height, .gray)
            Draw.vline(r.maxX - 1, r.minY, r.height, .gray)
        } else {
            Draw.bevel(.raisedButton, r)
        }
        PixelImages.draw(icon, centeredIn: r.offsetBy(dx: down ? 1 : 0, dy: down ? 1 : 0), enabled ? .normal : .embossed)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard enabled else { return }
        let p = convert(event.locationInWindow, from: nil)
        let at = vertical ? p.y : p.x
        let part: Part = at < trackStart ? .decrement
            : at >= length - Self.thickness ? .increment
            : at < thumbStart ? .pageUp
            : at >= thumbStart + thumbLength ? .pageDown : .thumb
        pressed = part
        if part == .thumb {
            dragThumb(from: at)
        } else {
            step(part)
            let start = Date()
            let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    if Date().timeIntervalSince(start) > 0.35 { self?.stepWhileHeld() }
                }
            }
            RunLoop.current.add(timer, forMode: .common)
            repeatTimer = timer
            while let next = window?.nextEvent(matching: [.leftMouseUp, .leftMouseDragged, .periodic], until: .distantFuture, inMode: .eventTracking, dequeue: true) {
                if next.type == .leftMouseUp { break }
            }
            repeatTimer?.invalidate()
            repeatTimer = nil
        }
        pressed = nil
    }

    private func stepWhileHeld() {
        guard let part = pressed, part != .thumb else { return }
        if part == .pageUp || part == .pageDown {
            let mouse = convert(window?.mouseLocationOutsideOfEventStream ?? .zero, from: nil)
            let at = vertical ? mouse.y : mouse.x
            if part == .pageUp && at >= thumbStart { return }
            if part == .pageDown && at < thumbStart + thumbLength { return }
        }
        step(part)
    }

    private func step(_ part: Part) {
        let delta: CGFloat = switch part {
        case .decrement: -line
        case .increment: line
        case .pageUp: -max(visible - line, line)
        case .pageDown: max(visible - line, line)
        case .thumb: 0
        }
        scroll(to: offset + delta)
    }

    private func dragThumb(from start: CGFloat) {
        let startOffset = offset
        let travel = max(trackLength - thumbLength, 1)
        while let next = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            let p = convert(next.locationInWindow, from: nil)
            let at = vertical ? p.y : p.x
            scroll(to: startOffset + (at - start) * maxOffset / travel)
            if next.type == .leftMouseUp { break }
        }
    }

    func scroll(to value: CGFloat) {
        let v = min(max(round(value), 0), maxOffset)
        guard v != offset else { return }
        offset = v
        onScroll?(v)
    }
}

/// An NSScrollView with its own scrollers hidden, framed by a sunken edge, with Win95
/// scrollbars that track the clip view.
final class Win95ScrollView: FaceView {
    let scrollView = NSScrollView()
    let vbar = Win95ScrollBar(vertical: true)
    let hbar = Win95ScrollBar(vertical: false)
    var showsHorizontal = false { didSet { needsLayout = true } }
    var frameBevel: Bevel? = .sunkenField { didSet { needsLayout = true; needsDisplay = true } }
    var documentBackground: Win95Color = .white

    override init(frame: NSRect) {
        super.init(frame: frame)
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.contentView.postsBoundsChangedNotifications = true
        addSubview(scrollView)
        addSubview(vbar)
        addSubview(hbar)
        vbar.onScroll = { [weak self] y in self?.scrollTo(x: nil, y: y) }
        hbar.onScroll = { [weak self] x in self?.scrollTo(x: x, y: nil) }
        NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scrollView.contentView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.sync() }
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    var documentView: NSView? {
        get { scrollView.documentView }
        set {
            scrollView.documentView = newValue
            newValue?.postsFrameChangedNotifications = true
            if let newValue {
                NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: newValue, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.sync() }
                }
            }
            sync()
        }
    }

    var inset: CGFloat { CGFloat(frameBevel?.thickness ?? 0) }

    override func layout() {
        super.layout()
        let inner = bounds.insetBy(dx: inset, dy: inset)
        let t = Win95ScrollBar.thickness
        let hb: CGFloat = showsHorizontal ? t : 0
        scrollView.frame = NSRect(x: inner.minX, y: inner.minY, width: inner.width - t, height: inner.height - hb)
        vbar.frame = NSRect(x: inner.maxX - t, y: inner.minY, width: t, height: inner.height - hb)
        hbar.isHidden = !showsHorizontal
        hbar.frame = NSRect(x: inner.minX, y: inner.maxY - t, width: inner.width - t, height: t)
        // A wrapping text view follows the visible width, and is at least as tall as the view
        // so clicks below the text still focus it.
        if let text = scrollView.documentView as? NSTextView, !text.isHorizontallyResizable {
            let size = scrollView.contentSize
            text.minSize = NSSize(width: 0, height: size.height)
            text.maxSize = NSSize(width: size.width, height: .greatestFiniteMagnitude)
            text.frame.size.width = size.width
            text.sizeToFit()
        }
        sync()
    }

    override func draw(_ dirtyRect: NSRect) {
        Draw.crisp()
        Draw.fill(bounds, .silver)
        if let frameBevel {
            Draw.fill(Draw.bevel(frameBevel, bounds), documentBackground)
        }
        if showsHorizontal {
            let inner = bounds.insetBy(dx: inset, dy: inset)
            Draw.fill(NSRect(x: inner.maxX - 16, y: inner.maxY - 16, width: 16, height: 16), .silver)
        }
    }

    func sync() {
        let clip = scrollView.contentView.bounds
        let doc = scrollView.documentView?.frame ?? .zero
        vbar.content = doc.height
        vbar.visible = clip.height
        vbar.offset = clip.minY
        hbar.content = doc.width
        hbar.visible = clip.width
        hbar.offset = clip.minX
    }

    func scrollTo(x: CGFloat?, y: CGFloat?) {
        let clip = scrollView.contentView.bounds
        scrollView.contentView.scroll(to: NSPoint(x: x ?? clip.minX, y: y ?? clip.minY))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        sync()
    }

    func scrollToBottom() {
        let doc = scrollView.documentView?.frame ?? .zero
        scrollTo(x: nil, y: max(doc.height - scrollView.contentView.bounds.height, 0))
    }
}
