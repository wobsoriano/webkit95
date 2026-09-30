import AppKit
import Webkit95Kit

/// IE3 style rebar: the button band and the address band stacked on the left, the animated
/// logo box on the right spanning both.
final class RebarView: FaceView {
    let toolbar = ToolbarBand()
    let address = AddressBand()
    let logo = LogoView()
    var showsToolbar = true { didSet { needsLayout = true; needsDisplay = true } }
    var showsAddress = true { didSet { needsLayout = true; needsDisplay = true } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(toolbar)
        addSubview(address)
        addSubview(logo)
    }

    required init?(coder: NSCoder) { fatalError() }

    var preferredHeight: CGFloat {
        let bands = (showsToolbar ? ToolbarBand.height + 2 : 0) + (showsAddress ? AddressBand.height + 2 : 0)
        return bands == 0 ? 0 : bands + 2
    }

    override func layout() {
        super.layout()
        let h = preferredHeight
        let logoSide = max(h - 4, 0)
        let bandsWidth = bounds.width - logoSide - 4
        var y: CGFloat = 2
        toolbar.isHidden = !showsToolbar
        address.isHidden = !showsAddress
        if showsToolbar {
            toolbar.frame = NSRect(x: 0, y: y, width: bandsWidth, height: ToolbarBand.height)
            y += ToolbarBand.height + 2
        }
        if showsAddress {
            address.frame = NSRect(x: 0, y: y, width: bandsWidth, height: AddressBand.height)
        }
        logo.isHidden = h == 0
        logo.frame = NSRect(x: bounds.width - logoSide - 2, y: 2, width: logoSide, height: logoSide)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        // Etched lines above the rebar and between bands, as in IE3.
        Draw.etched(horizontal: true, at: NSPoint(x: 0, y: 0), length: bounds.width)
        if showsToolbar && showsAddress {
            Draw.etched(horizontal: true, at: NSPoint(x: 0, y: toolbar.frame.maxY), length: bounds.width - logo.frame.width - 4)
        }
    }
}

/// The raised grip bar at the left of each band.
private func drawGrip(_ height: CGFloat) {
    Draw.bevel(.thinRaised, NSRect(x: 2, y: 2, width: 3, height: height - 4))
}

final class ToolbarBand: FaceView {
    static let height: CGFloat = 44
    struct Spec {
        let command: Command
        let label: String
        let icon: Icon
    }
    static let groups: [[Spec]] = [
        [Spec(command: .back, label: "Back", icon: .back),
         Spec(command: .forward, label: "Forward", icon: .forward),
         Spec(command: .stop, label: "Stop", icon: .stop),
         Spec(command: .refresh, label: "Refresh", icon: .refresh),
         Spec(command: .home, label: "Home", icon: .home)],
        [Spec(command: .search, label: "Search", icon: .search),
         Spec(command: .addFavorite, label: "Favorites", icon: .favorites),
         Spec(command: .toggleAssistant, label: "Assistant", icon: .assistant)],
        [Spec(command: .print, label: "Print", icon: .print),
         Spec(command: .textLarger, label: "Font", icon: .font)],
    ]
    private(set) var buttons: [Command: Win95Button] = [:]
    private var separators: [CGFloat] = []
    var onCommand: ((Command, Win95Button) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        for spec in Self.groups.joined() {
            let b = Win95Button(spec.label, style: .toolbar, icon: spec.icon)
            b.action = { [weak self, weak b] in
                guard let self, let b else { return }
                self.onCommand?(spec.command, b)
            }
            addSubview(b)
            buttons[spec.command] = b
        }
        setAccessibilityRole(.toolbar)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        var x: CGFloat = 10
        separators = []
        for (gi, group) in Self.groups.enumerated() {
            if gi > 0 {
                separators.append(x + 2)
                x += 6
            }
            for spec in group {
                let w = max(Draw.width(spec.label) + 12, 48)
                buttons[spec.command]?.frame = NSRect(x: x, y: 1, width: w, height: Self.height - 2)
                x += w
            }
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        drawGrip(bounds.height)
        for x in separators { Draw.etched(horizontal: false, at: NSPoint(x: x, y: 3), length: bounds.height - 6) }
    }
}

final class AddressBand: FaceView {
    static let height: CGFloat = 26
    let combo = AddressCombo()

    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(combo)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let labelW = Draw.width("Address") + 8
        combo.frame = NSRect(x: 10 + labelW, y: 2, width: bounds.width - 10 - labelW - 4, height: 22)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        drawGrip(bounds.height)
        Draw.text("Address", at: NSPoint(x: 11, y: 5), underline: 1)
    }
}

/// A Win95 combo box: sunken white well with a page icon, the text field, and a raised drop
/// down button inside the well.
final class AddressCombo: FaceView {
    let field = PixelTextField(string: "")
    let dropButton = Win95Button("", style: .titleBar, icon: .comboArrow)
    var icon: Icon = .page { didSet { needsDisplay = true } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(field)
        addSubview(dropButton)
        field.setAccessibilityIdentifier("address")
        field.setAccessibilityLabel("Address")
        dropButton.setAccessibilityLabel("Recent addresses")
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        dropButton.frame = NSRect(x: bounds.width - 2 - 16, y: 2, width: 16, height: bounds.height - 4)
        field.frame = NSRect(x: 22, y: floor((bounds.height - Fonts.lineHeight) / 2), width: bounds.width - 22 - 20, height: Fonts.lineHeight)
    }

    override func draw(_ dirtyRect: NSRect) {
        let inner = Draw.bevel(.sunkenField, bounds)
        Draw.fill(inner, .white)
        PixelImages.draw(icon, at: NSPoint(x: 4, y: floor((bounds.height - 16) / 2)))
    }
}

/// The logo box: an original spinning globe while a page loads, resting otherwise.
final class LogoView: FaceView {
    private var frameIndex = 0
    private var timer: Timer?
    var isAnimating = false {
        didSet {
            guard oldValue != isAnimating else { return }
            timer?.invalidate()
            timer = nil
            if isAnimating {
                let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.frameIndex = (self.frameIndex + 1) % Icons.logoFrames.count
                        self.needsDisplay = true
                    }
                }
                RunLoop.main.add(t, forMode: .common)
                timer = t
            } else {
                frameIndex = 0
                needsDisplay = true
            }
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityRole(.image)
        setAccessibilityLabel("webkit95 logo")
    }

    required init?(coder: NSCoder) { fatalError() }

    var currentFrame: Int { frameIndex }

    override func draw(_ dirtyRect: NSRect) {
        Draw.crisp()
        let inner = Draw.bevel(.thinSunken, bounds)
        Draw.fill(inner, .black)
        let art = Icons.logoFrames[frameIndex]
        let scale = max(floor(min(inner.width, inner.height) / CGFloat(art.width)), 1)
        let w = CGFloat(art.width) * scale, h = CGFloat(art.height) * scale
        PixelImages.draw(art, at: NSPoint(x: floor(inner.midX - w / 2), y: floor(inner.midY - h / 2)), scale: scale)
    }
}

/// Status text, progress, zone and the size grip.
final class StatusBarView: FaceView {
    static let height: CGFloat = 20
    var text = "" { didSet { if oldValue != text { needsDisplay = true; setAccessibilityValue(text) } } }
    var zone: SecurityZone = .internet { didSet { if oldValue != zone { needsDisplay = true } } }
    let progress = Win95Progress()
    var showsProgress = false { didSet { progress.isHidden = !showsProgress } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(progress)
        progress.isHidden = true
        setAccessibilityRole(.staticText)
        setAccessibilityIdentifier("status")
    }

    required init?(coder: NSCoder) { fatalError() }

    private var zoneWidth: CGFloat { 150 }
    private var progressWidth: CGFloat { 110 }

    override func layout() {
        super.layout()
        let right = bounds.width - 14 - zoneWidth - 2
        progress.frame = NSRect(x: right - progressWidth, y: 2, width: progressWidth, height: bounds.height - 2)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let zoneRect = NSRect(x: bounds.width - 14 - zoneWidth, y: 2, width: zoneWidth, height: bounds.height - 2)
        let progressRect = NSRect(x: zoneRect.minX - 2 - progressWidth, y: 2, width: progressWidth, height: bounds.height - 2)
        let textRect = NSRect(x: 0, y: 2, width: progressRect.minX - 2, height: bounds.height - 2)
        Draw.bevel(.thinSunken, textRect)
        Draw.text(TitleBarView.truncate(text, width: textRect.width - 8, bold: false), at: NSPoint(x: textRect.minX + 4, y: textRect.minY + 1))
        if !showsProgress { Draw.bevel(.thinSunken, progressRect) }
        Draw.bevel(.thinSunken, zoneRect)
        PixelImages.draw(.zone, at: NSPoint(x: zoneRect.minX + 3, y: zoneRect.minY + 1))
        Draw.text(zone.title, at: NSPoint(x: zoneRect.minX + 22, y: zoneRect.minY + 1))
        drawSizeGrip()
    }

    // Three diagonal white and gray ridges in the bottom right corner.
    private func drawSizeGrip() {
        let x0 = bounds.width - 12, y0 = bounds.height - 12
        for i in 0..<12 {
            for j in 0..<12 where i + j >= 11 {
                let d = (i + j - 11) % 4
                let c: Win95Color? = d == 0 ? .white : (d == 1 || d == 2 ? .gray : nil)
                if let c { Draw.fill(NSRect(x: x0 + CGFloat(i), y: y0 + CGFloat(j), width: 1, height: 1), c) }
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if p.x > bounds.width - 16, let w = window as? Win95Window {
            w.trackResize(event, edges: [.maxX, .minY])
        }
    }
}

/// The 2 px sunken frame around the web view.
final class SunkenContainer: FaceView {
    var content: NSView? {
        didSet {
            oldValue?.removeFromSuperview()
            if let content { addSubview(content) }
            needsLayout = true
        }
    }

    override func layout() {
        super.layout()
        content?.frame = bounds.insetBy(dx: 2, dy: 2)
    }

    override func draw(_ dirtyRect: NSRect) {
        Draw.crisp()
        Draw.fill(Draw.bevel(.sunkenField, bounds), .white)
    }
}

/// A vertical bar the user drags to size the Explorer Bar.
final class SplitterView: FaceView {
    var onDrag: ((CGFloat) -> Void)?

    override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeLeftRight) }

    override func mouseDown(with event: NSEvent) {
        let start = event.locationInWindow.x
        while let next = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            onDrag?(round(next.locationInWindow.x - start))
            if next.type == .leftMouseUp { break }
        }
        onDrag?(.nan)
    }
}
