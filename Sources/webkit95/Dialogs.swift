import AppKit
import Webkit95Kit

/// Holds Win95 dialogs above the window content. No dimming: the parent stays visible. A
/// modal dialog takes every click and key; a modeless one (Find, File Download) only its own.
final class DialogLayer: NSView {
    private(set) var dialogs: [DialogView] = []
    var onChange: (() -> Void)?

    override var isFlipped: Bool { true }

    var hasModal: Bool { dialogs.contains { $0.isModal } }
    var top: DialogView? { dialogs.last }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        for d in dialogs.reversed() where d.frame.contains(local) {
            return d.hitTest(convert(local, to: d.superview)) ?? d
        }
        return hasModal ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        NSSound.beep()
        top?.flash()
    }

    func present(_ dialog: DialogView) {
        let size = dialog.fittingSize
        let origin = NSPoint(x: floor((bounds.width - size.width) / 2), y: max(floor((bounds.height - size.height) / 2.5), 24))
        dialog.frame = NSRect(origin: origin, size: size)
        addSubview(dialog)
        dialogs.append(dialog)
        dialog.layer_ = self
        dialog.takeFocus()
        onChange?()
    }

    func dismiss(_ dialog: DialogView) {
        guard let i = dialogs.firstIndex(where: { $0 === dialog }) else { return }
        dialogs.remove(at: i)
        dialog.removeFromSuperview()
        if let next = dialogs.last { next.takeFocus() } else { dialog.restoreFocus() }
        onChange?()
    }

    func dialog(kind: String) -> DialogView? { dialogs.last { $0.kind == kind } }

    override func layout() {
        super.layout()
        for d in dialogs {
            var f = d.frame
            f.origin.x = min(max(f.origin.x, 0), max(bounds.width - f.width, 0))
            f.origin.y = min(max(f.origin.y, 0), max(bounds.height - f.height, 0))
            d.frame = f
        }
    }
}

/// A classic dialog: title bar with a close X, a face colored body, and controls with Win95
/// keyboard focus (Tab, arrows, Return for the default button, Escape for Cancel).
class DialogView: FaceView, NSTextFieldDelegate {
    let kind: String
    let isModal: Bool
    let titleBar = TitleBarView()
    let body = FaceView()
    var focus: DialogFocus
    private var controls: [DialogFocus.Control: NSView] = [:]
    private var buttonActions: [String: () -> Void] = [:]
    weak var layer_: DialogLayer?
    private weak var previousResponder: NSResponder?
    private var contentSize: NSSize
    /// Escape, the close box and Cancel all call this.
    var onCancel: (() -> Void)?
    /// A message box's text, for the control socket.
    var message: String?

    init(kind: String, title: String, modal: Bool = true, size: NSSize) {
        self.kind = kind
        self.isModal = modal
        self.contentSize = size
        focus = DialogFocus(controls: [], defaultButton: nil, cancelButton: nil)
        super.init(frame: .zero)
        titleBar.title = title
        titleBar.icon = nil
        titleBar.showsMinMax = false
        titleBar.onClose = { [weak self] in self?.cancel() }
        titleBar.onDrag = { [weak self] event in self?.drag(from: event) }
        addSubview(titleBar)
        addSubview(body)
        setAccessibilityRole(.group)
        setAccessibilityIdentifier("dialog-\(kind)")
        setAccessibilityLabel(title)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var fittingSize: NSSize { NSSize(width: contentSize.width + 8, height: contentSize.height + 8 + TitleBarView.height + 1) }
    override var acceptsFirstResponder: Bool { true }

    override func layout() {
        super.layout()
        titleBar.frame = NSRect(x: 3, y: 3, width: bounds.width - 6, height: TitleBarView.height)
        body.frame = NSRect(x: 4, y: 3 + TitleBarView.height + 1, width: bounds.width - 8, height: bounds.height - TitleBarView.height - 8)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        Draw.bevel(.windowFrame, bounds)
    }

    // MARK: building

    @discardableResult
    func addButton(_ id: String, _ label: String, frame: NSRect, style: Win95Button.Style = .push, action: @escaping () -> Void) -> Win95Button {
        let b = Win95Button(label, style: style)
        b.frame = frame
        b.action = { [weak self] in
            self?.focus.focus(.button(id))
            self?.syncFocus()
            action()
        }
        body.addSubview(b)
        controls[.button(id)] = b
        buttonActions[id] = action
        return b
    }

    func register(_ control: DialogFocus.Control, _ view: NSView) {
        controls[control] = view
        if let field = view as? SunkenField { field.field.delegate = self }
        if let field = view as? NSTextField { field.delegate = self }
    }

    /// Call after adding every control, in Tab order.
    func setFocusOrder(_ order: [DialogFocus.Control], defaultButton: String?, cancelButton: String?, initial: DialogFocus.Control? = nil) {
        focus = DialogFocus(controls: order, defaultButton: defaultButton, cancelButton: cancelButton, initial: initial)
    }

    /// Lays out push buttons 75x23 (or wider for long labels), 6 px apart, centered at `y`.
    func centeredButtons(_ specs: [(String, String, () -> Void)], y: CGFloat, width: CGFloat) {
        let widths = specs.map { Win95Button.pushWidth($0.1) }
        let total = widths.reduce(0, +) + CGFloat(max(specs.count - 1, 0)) * 6
        var x = floor((width - total) / 2)
        for (i, spec) in specs.enumerated() {
            addButton(spec.0, spec.1, frame: NSRect(x: x, y: y, width: widths[i], height: 23), action: spec.2)
            x += widths[i] + 6
        }
    }

    // MARK: focus

    func takeFocus() {
        if previousResponder == nil { previousResponder = window?.firstResponder }
        syncFocus()
    }

    func restoreFocus() {
        if let previousResponder, previousResponder !== self { window?.makeFirstResponder(previousResponder) }
    }

    func syncFocus() {
        let def = focus.effectiveDefault
        let focused = focus.focused
        for (control, view) in controls {
            let isFocused = control == focused
            switch view {
            case let b as Win95Button:
                if case let .button(id) = control { b.isDefault = id == def }
                b.hasFocusRing = isFocused
            case let c as Win95Checkbox: c.hasFocusRing = isFocused
            case let r as Win95Radio: r.hasFocusRing = isFocused
            default: break
            }
        }
        guard let window else { return }
        switch focused.flatMap({ controls[$0] }) {
        case let field as SunkenField:
            if field.field.currentEditor() == nil {
                window.makeFirstResponder(field.field)
                field.field.currentEditor()?.selectAll(nil)
            }
        case let scroll as Win95ScrollView:
            window.makeFirstResponder(scroll.scrollView.documentView)
        default:
            if window.firstResponder !== self { window.makeFirstResponder(self) }
        }
    }

    func buttonView(_ id: String) -> NSView? { controls[.button(id)] }

    func press(_ id: String) {
        buttonActions[id]?()
    }

    func cancel() {
        if let onCancel { onCancel() } else if let c = focus.cancelButton { press(c) }
    }

    func close() { layer_?.dismiss(self) }

    func flash() {
        titleBar.isActive = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in self?.titleBar.isActive = true }
    }

    private func activateFocused() {
        switch focus.focused {
        case let .button(id)?: press(id)
        case let .checkbox(id)?: (controls[.checkbox(id)] as? Win95Checkbox)?.toggle()
        case let .radio(id)?: (controls[.radio(id)] as? Win95Radio)?.onSelect?()
        default: break
        }
    }

    override func keyDown(with event: NSEvent) {
        let shift = event.modifierFlags.contains(.shift)
        switch event.keyCode {
        case 48: focus.tab(backward: shift); syncFocus()
        case 123, 126: if focus.arrow(forward: false) { syncFocus() }
        case 124, 125: if focus.arrow(forward: true) { syncFocus() }
        case 36, 76: if let d = focus.effectiveDefault { press(d) }
        case 53: cancel()
        case 49: activateFocused()
        default:
            guard let c = event.charactersIgnoringModifiers?.lowercased().first else { return }
            for control in focus.controls {
                let label: MenuLabel? = switch controls[control] {
                case let b as Win95Button: b.label
                case let cb as Win95Checkbox: cb.label
                case let r as Win95Radio: r.label
                default: nil
                }
                if label?.mnemonic == c {
                    focus.focus(control)
                    syncFocus()
                    activateFocused()
                    return
                }
            }
        }
    }

    // Clicks on the dialog's own face stay here; the layer behind it beeps for clicks outside.
    override func mouseDown(with event: NSEvent) {}

    private func drag(from event: NSEvent) {
        guard let window else { return }
        let start = event.locationInWindow
        let origin = frame.origin
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            let p = next.locationInWindow
            // The layer is flipped, window coordinates are not.
            setFrameOrigin(NSPoint(x: round(origin.x + p.x - start.x), y: round(origin.y - (p.y - start.y))))
            if next.type == .leftMouseUp { break }
        }
        superview?.needsLayout = true
    }

    // Text fields hand Tab, Return and Escape to the dialog.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertTab(_:)):
            focus.tab(); syncFocus(); return true
        case #selector(NSResponder.insertBacktab(_:)):
            focus.tab(backward: true); syncFocus(); return true
        case #selector(NSResponder.insertNewline(_:)):
            if let d = focus.effectiveDefault { press(d) }
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            cancel(); return true
        default:
            return false
        }
    }

    func controlTextDidBeginEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        if let (control, _) = controls.first(where: { ($0.value as? SunkenField)?.field === field }) {
            focus.focus(control)
            syncFocus()
        }
    }
}

extension DialogView {
    /// Message box: icon at the left, wrapped text, centered buttons.
    static func messageBox(kind: String, title: String, icon: Icon?, message: String,
                           buttons: [(id: String, label: String)], defaultButton: String, cancelButton: String?,
                           result: @escaping (String) -> Void) -> DialogView {
        let textWidth = min(max(Draw.width(message) + 4, 180), 360)
        let lines = Draw.wrap(message, width: textWidth)
        let textHeight = max(CGFloat(lines.count) * Fonts.lineHeight, icon == nil ? 16 : 32)
        let iconSpace: CGFloat = icon == nil ? 0 : 32 + 16
        let buttonsWidth = buttons.map { Win95Button.pushWidth($0.label) }.reduce(0, +) + CGFloat(buttons.count - 1) * 6
        let width = max(12 + iconSpace + textWidth + 12, buttonsWidth + 24)
        let height = 12 + textHeight + 14 + 23 + 10
        let d = DialogView(kind: kind, title: title, size: NSSize(width: width, height: height))
        d.message = message
        if let icon {
            let iv = IconView(icon: icon)
            iv.frame = NSRect(x: 12, y: 12, width: 32, height: 32)
            d.body.addSubview(iv)
        }
        let label = Win95Label(message)
        label.wraps = true
        label.frame = NSRect(x: 12 + iconSpace, y: 12 + (lines.count == 1 && icon != nil ? 8 : 0), width: textWidth, height: CGFloat(lines.count) * Fonts.lineHeight)
        d.body.addSubview(label)
        d.centeredButtons(buttons.map { b in (b.id, b.label, { [weak d] in d?.close(); result(b.id) }) }, y: height - 23 - 10, width: width)
        d.setFocusOrder(buttons.map { .button($0.id) }, defaultButton: defaultButton, cancelButton: cancelButton)
        if cancelButton == nil { d.onCancel = { [weak d] in d?.close(); result(defaultButton) } }
        return d
    }
}

/// A pixel icon at 1x in a view.
final class IconView: FaceView {
    var art: PixelArt { didSet { needsDisplay = true } }
    init(icon: Icon) {
        art = icon.art
        super.init(frame: .zero)
        background = nil
    }
    init(art: PixelArt) {
        self.art = art
        super.init(frame: .zero)
        background = nil
    }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) { PixelImages.draw(art, at: .zero) }
}
