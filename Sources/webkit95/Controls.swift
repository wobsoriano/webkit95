import AppKit
import Webkit95Kit

/// A flipped view that paints the button face color, the base of every Win95 surface.
class FaceView: NSView {
    var background: Win95Color? = .silver { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { background != nil }

    override init(frame: NSRect) {
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        Draw.crisp()
        if let background { Draw.fill(bounds, background) }
    }
}

/// Push buttons, toolbar buttons and title bar buttons.
final class Win95Button: FaceView {
    enum Style { case push, toolbar, titleBar, small }

    var style: Style
    var label: MenuLabel { didSet { needsDisplay = true } }
    var icon: Icon? { didSet { needsDisplay = true } }
    var isEnabled = true { didSet { needsDisplay = true } }
    var isDefault = false { didSet { needsDisplay = true } }
    var hasFocusRing = false { didSet { needsDisplay = true } }
    /// Toolbar toggle that stays pushed in (the Assistant button while its bar is open).
    var isLatched = false { didSet { needsDisplay = true } }
    var action: (() -> Void)?

    private var pressed = false { didSet { needsDisplay = true } }
    private var hovering = false { didSet { needsDisplay = true } }
    private var tracking: NSTrackingArea?

    init(_ label: String, style: Style = .push, icon: Icon? = nil, action: (() -> Void)? = nil) {
        self.style = style
        self.label = MenuLabel(label)
        self.icon = icon
        self.action = action
        super.init(frame: .zero)
        setAccessibilityRole(.button)
        setAccessibilityLabel(self.label.text.isEmpty ? icon?.rawValue : self.label.text)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        action?()
        return true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        pressed = true
        var inside = true
        while let next = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            inside = bounds.contains(convert(next.locationInWindow, from: nil))
            pressed = inside
            if next.type == .leftMouseUp { break }
        }
        pressed = false
        if inside { action?() }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        switch style {
        case .push, .small: drawPush()
        case .titleBar: drawTitleButton()
        case .toolbar: drawToolbar()
        }
    }

    private func drawPush() {
        if isDefault {
            Draw.defaultButton(bounds, pressed: pressed)
        } else {
            Draw.bevel(pressed ? .pressedButton : .raisedButton, bounds)
        }
        let shift: CGFloat = pressed ? 1 : 0
        var contentWidth = Draw.width(label.text)
        if let icon { contentWidth += CGFloat(icon.art.width) + (label.text.isEmpty ? 0 : 4) }
        var x = floor((bounds.width - contentWidth) / 2) + shift
        let textY = floor((bounds.height - Fonts.lineHeight) / 2) + shift
        if let icon {
            let art = icon.art
            PixelImages.draw(icon, at: NSPoint(x: x, y: floor((bounds.height - CGFloat(art.height)) / 2) + shift), isEnabled ? .normal : .embossed)
            x += CGFloat(art.width) + 4
        }
        if !label.text.isEmpty {
            if isEnabled {
                Draw.text(label.text, at: NSPoint(x: x, y: textY), underline: label.mnemonicIndex)
            } else {
                Draw.embossedText(label.text, at: NSPoint(x: x, y: textY), underline: label.mnemonicIndex)
            }
        }
        if hasFocusRing {
            Draw.focusRect(bounds.insetBy(dx: isDefault ? 4 : 3, dy: isDefault ? 4 : 3))
        }
    }

    private func drawTitleButton() {
        Draw.bevel(pressed ? .pressedButton : .raisedButton, bounds)
        guard let icon else { return }
        let art = icon.art
        let shift: CGFloat = pressed ? 1 : 0
        let origin = NSPoint(x: floor((bounds.width - CGFloat(art.width)) / 2) + shift,
                             y: floor((bounds.height - CGFloat(art.height)) / 2) + shift)
        PixelImages.draw(art, at: origin, isEnabled ? .normal : .embossed)
    }

    /// IE4 style: flat until hovered, then a thin raised edge; pushed shows thin sunken.
    private func drawToolbar() {
        let down = (pressed && hovering) || isLatched
        if isEnabled {
            if down {
                if isLatched && !pressed { Draw.dither(bounds.insetBy(dx: 1, dy: 1), .silver, .white) }
                Draw.bevel(.thinSunken, bounds)
            } else if hovering {
                Draw.bevel(.thinRaised, bounds)
            }
        }
        let shift: CGFloat = down ? 1 : 0
        let variant: PixelImages.Variant = !isEnabled ? .embossed : (hovering || down ? .normal : .gray)
        if let icon {
            let art = icon.art
            PixelImages.draw(icon, at: NSPoint(x: floor((bounds.width - CGFloat(art.width)) / 2) + shift, y: 4 + shift), variant)
        }
        let tw = Draw.width(label.text)
        let origin = NSPoint(x: floor((bounds.width - tw) / 2) + shift, y: bounds.height - Fonts.lineHeight - 3 + shift)
        if isEnabled {
            Draw.text(label.text, at: origin)
        } else {
            Draw.embossedText(label.text, at: origin)
        }
    }

    static func pushWidth(_ label: String) -> CGFloat { max(75, Draw.width(MenuLabel(label).text) + 16) }
}

/// Classic checkbox: a 13x13 sunken white well with a black check.
final class Win95Checkbox: FaceView {
    var label: MenuLabel { didSet { needsDisplay = true } }
    var isOn: Bool { didSet { needsDisplay = true } }
    var hasFocusRing = false { didSet { needsDisplay = true } }
    var onChange: ((Bool) -> Void)?
    private var pressed = false { didSet { needsDisplay = true } }

    init(_ label: String, isOn: Bool) {
        self.label = MenuLabel(label)
        self.isOn = isOn
        super.init(frame: .zero)
        setAccessibilityRole(.checkBox)
        setAccessibilityLabel(self.label.text)
    }

    required init?(coder: NSCoder) { fatalError() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func accessibilityValue() -> Any? { isOn ? 1 : 0 }
    override func accessibilityPerformPress() -> Bool { toggle(); return true }

    func toggle() {
        isOn.toggle()
        onChange?(isOn)
    }

    override func mouseDown(with event: NSEvent) {
        pressed = true
        var inside = true
        while let next = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            inside = bounds.contains(convert(next.locationInWindow, from: nil))
            pressed = inside
            if next.type == .leftMouseUp { break }
        }
        pressed = false
        if inside { toggle() }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let box = NSRect(x: 0, y: floor((bounds.height - 13) / 2), width: 13, height: 13)
        let inner = Draw.bevel(.sunkenField, box)
        Draw.fill(inner, pressed ? .silver : .white)
        if isOn { PixelImages.draw(.check, at: NSPoint(x: inner.minX + 1, y: inner.minY + 1)) }
        let textX: CGFloat = 19
        let textY = floor((bounds.height - Fonts.lineHeight) / 2)
        Draw.text(label.text, at: NSPoint(x: textX, y: textY), underline: label.mnemonicIndex)
        if hasFocusRing {
            Draw.focusRect(NSRect(x: textX - 2, y: textY, width: Draw.width(label.text) + 4, height: Fonts.lineHeight))
        }
    }
}

/// Classic round radio button.
final class Win95Radio: FaceView {
    var label: MenuLabel { didSet { needsDisplay = true } }
    var isOn: Bool { didSet { needsDisplay = true } }
    var hasFocusRing = false { didSet { needsDisplay = true } }
    var onSelect: (() -> Void)?

    // Outer ring gray and black on the top left, white and light on the bottom right.
    private static let well = PixelArt([
        "....gggg....",
        "..ggkkkkgg..",
        ".gkkwwwwkkw.",
        ".gkwwwwwwlw.",
        "gkwwwwwwwwlw",
        "gkwwwwwwwwlw",
        "gkwwwwwwwwlw",
        "gkwwwwwwwwlw",
        ".gkwwwwwwlw.",
        ".glllwwlllw.",
        "..wwllllww..",
        "....wwww....",
    ])
    private static let dot = PixelArt([
        ".kk.",
        "kkkk",
        "kkkk",
        ".kk.",
    ])

    init(_ label: String, isOn: Bool) {
        self.label = MenuLabel(label)
        self.isOn = isOn
        super.init(frame: .zero)
        setAccessibilityRole(.radioButton)
        setAccessibilityLabel(self.label.text)
    }

    required init?(coder: NSCoder) { fatalError() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func accessibilityValue() -> Any? { isOn ? 1 : 0 }
    override func accessibilityPerformPress() -> Bool { onSelect?(); return true }
    override func mouseDown(with event: NSEvent) { onSelect?() }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let y = floor((bounds.height - 12) / 2)
        PixelImages.draw(Self.well, at: NSPoint(x: 0, y: y))
        if isOn { PixelImages.draw(Self.dot, at: NSPoint(x: 4, y: y + 4)) }
        let textY = floor((bounds.height - Fonts.lineHeight) / 2)
        Draw.text(label.text, at: NSPoint(x: 18, y: textY), underline: label.mnemonicIndex)
        if hasFocusRing {
            Draw.focusRect(NSRect(x: 16, y: textY, width: Draw.width(label.text) + 4, height: Fonts.lineHeight))
        }
    }
}

/// An etched frame with its title set into the top edge.
final class Win95GroupBox: FaceView {
    var title: String { didSet { needsDisplay = true } }

    init(_ title: String) {
        self.title = title
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let top: CGFloat = 7
        Draw.bevel(.groove, NSRect(x: 0, y: top, width: bounds.width, height: bounds.height - top))
        let tw = Draw.width(title)
        Draw.fill(NSRect(x: 6, y: 0, width: tw + 4, height: Fonts.lineHeight), .silver)
        Draw.text(title, at: NSPoint(x: 8, y: 0))
    }
}

/// Plain text label on the face color.
final class Win95Label: FaceView {
    var text: String { didSet { needsDisplay = true } }
    var bold = false
    var wraps = false
    var color: Win95Color = .black

    init(_ text: String, background: Win95Color? = .silver) {
        self.text = text
        super.init(frame: .zero)
        self.background = background
        setAccessibilityRole(.staticText)
    }

    required init?(coder: NSCoder) { fatalError() }
    override func accessibilityValue() -> Any? { text }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if wraps {
            Draw.wrapped(text, in: bounds, color: color, bold: bold)
        } else {
            let label = MenuLabel(text)
            Draw.text(label.text, at: NSPoint(x: 0, y: floor((bounds.height - Fonts.lineHeight) / 2)), color: color, bold: bold, underline: label.mnemonicIndex)
        }
    }
}

/// The segmented navy progress bar of Windows 95 in a thin sunken well.
final class Win95Progress: FaceView {
    var fraction: Double = 0 { didSet { if oldValue != fraction { needsDisplay = true } } }
    var sunken: Bevel = .thinSunken

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let inner = Draw.bevel(sunken, bounds).insetBy(dx: 1, dy: 1)
        let blockW: CGFloat = max(floor(inner.height * 0.6), 6)
        let step = blockW + 2
        let filled = inner.width * CGFloat(min(max(fraction, 0), 1))
        var x = inner.minX
        while x + blockW <= inner.minX + filled + 0.5, x + blockW <= inner.maxX {
            Draw.fill(NSRect(x: x, y: inner.minY, width: blockW, height: inner.height), .navy)
            x += step
        }
    }
}

/// A text field inside a 2 px sunken white well. The field itself draws without anti aliasing.
final class SunkenField: FaceView {
    let field: PixelTextField

    init(text: String = "") {
        field = PixelTextField(string: text)
        super.init(frame: .zero)
        addSubview(field)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        field.frame = NSRect(x: 4, y: floor((bounds.height - Fonts.lineHeight) / 2), width: bounds.width - 8, height: Fonts.lineHeight)
    }

    override func draw(_ dirtyRect: NSRect) {
        let inner = Draw.bevel(.sunkenField, bounds)
        Draw.fill(inner, field.isEnabled ? .white : .silver)
    }
}

final class PixelTextField: NSTextField {
    convenience init(string: String) {
        self.init(frame: .zero)
        stringValue = string
        isBordered = false
        drawsBackground = false
        focusRingType = .none
        font = Fonts.ui
        textColor = Win95Color.black.ns
        cell?.isScrollable = true
        cell?.wraps = false
        cell?.usesSingleLineMode = true
    }

    override func draw(_ dirtyRect: NSRect) {
        Draw.crisp()
        super.draw(dirtyRect)
    }
}

/// The field editor and multi line editors: text without anti aliasing, navy selection.
final class PixelTextView: NSTextView {
    override func draw(_ dirtyRect: NSRect) {
        Draw.crisp()
        super.draw(dirtyRect)
    }

    static func configure(_ tv: NSTextView) {
        tv.font = Fonts.ui
        tv.textColor = Win95Color.black.ns
        tv.insertionPointColor = Win95Color.black.ns
        tv.selectedTextAttributes = [.backgroundColor: Win95Color.navy.ns, .foregroundColor: Win95Color.white.ns]
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isContinuousSpellCheckingEnabled = false
    }
}
