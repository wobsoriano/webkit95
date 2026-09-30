import AppKit
import Webkit95Kit

/// The File Edit View Go Favorites Help row. Titles come from `MenuModel`.
final class MenuBarView: FaceView {
    static let height: CGFloat = 20
    var menus: [Menu] = [] { didSet { needsDisplay = true; rebuildAccessibility() } }
    /// Index of the menu drawn highlighted (open).
    var openIndex: Int? { didSet { if oldValue != openIndex { needsDisplay = true } } }
    var onOpen: ((Int) -> Void)?

    func itemRects() -> [NSRect] {
        var x: CGFloat = 2
        return menus.map { menu in
            let w = Draw.width(menu.label.text) + 12
            defer { x += w }
            return NSRect(x: x, y: 1, width: w, height: Self.height - 2)
        }
    }

    func index(at p: NSPoint) -> Int? { itemRects().firstIndex { $0.contains(p) } }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        for (i, r) in itemRects().enumerated() {
            let open = i == openIndex
            if open { Draw.fill(r, .navy) }
            let label = menus[i].label
            Draw.text(label.text, at: NSPoint(x: r.minX + 6, y: r.minY + 1), color: open ? .white : .black, underline: label.mnemonicIndex)
        }
    }

    override func mouseDown(with event: NSEvent) {
        if let i = index(at: convert(event.locationInWindow, from: nil)) { onOpen?(i) }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func rebuildAccessibility() {
        let rects = itemRects()
        let children: [NSAccessibilityElement] = menus.enumerated().map { i, menu in
            let e = NSAccessibilityElement()
            e.setAccessibilityRole(.menuBarItem)
            e.setAccessibilityLabel(menu.label.text)
            e.setAccessibilityParent(self)
            e.setAccessibilityFrameInParentSpace(rects[i])
            return e
        }
        setAccessibilityChildren(children)
        setAccessibilityRole(.menuBar)
    }
}

/// One dropdown panel of menu rows.
final class PopupMenuView: FaceView {
    let entries: [MenuEntry]
    var selected: Int? { didSet { if oldValue != selected { needsDisplay = true } } }
    static let rowHeight: CGFloat = 18
    static let separatorHeight: CGFloat = 8

    init(entries: [MenuEntry]) {
        self.entries = entries
        super.init(frame: .zero)
        setAccessibilityRole(.menu)
        setAccessibilityIdentifier("popup-menu")
        setAccessibilityChildren(entries.enumerated().compactMap { i, e -> NSAccessibilityElement? in
            guard let label = e.label else { return nil }
            let el = NSAccessibilityElement()
            el.setAccessibilityRole(.menuItem)
            el.setAccessibilityLabel(label.text)
            el.setAccessibilityEnabled(e.isEnabled)
            el.setAccessibilityParent(self)
            el.setAccessibilityFrameInParentSpace(rowRect(i))
            return el
        })
    }

    required init?(coder: NSCoder) { fatalError() }

    var size: NSSize {
        var textW: CGFloat = 0, keyW: CGFloat = 0
        for e in entries {
            if let l = e.label { textW = max(textW, Draw.width(l.text)) }
            if case let .item(item) = e, let s = item.shortcut { keyW = max(keyW, Draw.width(s.display)) }
        }
        let width = 3 + 20 + textW + (keyW > 0 ? 24 + keyW : 0) + 24 + 3
        let height = entries.reduce(CGFloat(6)) { $0 + (($1 == .separator) ? Self.separatorHeight : Self.rowHeight) }
        return NSSize(width: max(ceil(width), 120), height: height)
    }

    func rowRect(_ index: Int) -> NSRect {
        var y: CGFloat = 3
        for i in 0..<index { y += entries[i] == .separator ? Self.separatorHeight : Self.rowHeight }
        let h = entries[index] == .separator ? Self.separatorHeight : Self.rowHeight
        return NSRect(x: 3, y: y, width: size.width - 6, height: h)
    }

    func row(at p: NSPoint) -> Int? {
        entries.indices.first { rowRect($0).contains(p) }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        Draw.bevel(.windowFrame, bounds)
        for (i, entry) in entries.enumerated() {
            let r = rowRect(i)
            switch entry {
            case .separator:
                Draw.etched(horizontal: true, at: NSPoint(x: r.minX + 1, y: r.midY - 1), length: r.width - 2)
            case let .item(item):
                drawRow(r, label: item.label, enabled: item.isEnabled, selected: i == selected, check: item.check, shortcut: item.shortcut?.display, submenu: false)
                if let icon = item.icon { PixelImages.draw(icon, at: NSPoint(x: r.minX + 2, y: r.minY + 1)) }
            case let .submenu(menu):
                drawRow(r, label: menu.label, enabled: entry.isEnabled, selected: i == selected, check: .none, shortcut: nil, submenu: true)
            }
        }
    }

    private func drawRow(_ r: NSRect, label: MenuLabel, enabled: Bool, selected: Bool, check: MenuCheck, shortcut: String?, submenu: Bool) {
        let highlight = selected
        if highlight { Draw.fill(r, .navy) }
        let fg: Win95Color = highlight ? .white : .black
        let textY = r.minY + 1
        let glyphVariant: PixelImages.Variant = highlight ? .white : (enabled ? .normal : .embossed)
        switch check {
        case .check: PixelImages.draw(.check, at: NSPoint(x: r.minX + 6, y: r.minY + 6), glyphVariant)
        case .radio: PixelImages.draw(.radio, at: NSPoint(x: r.minX + 6, y: r.minY + 6), glyphVariant)
        case .none: break
        }
        let textX = r.minX + 20
        if enabled {
            Draw.text(label.text, at: NSPoint(x: textX, y: textY), color: fg, underline: label.mnemonicIndex)
            if let shortcut { Draw.text(shortcut, at: NSPoint(x: r.maxX - 22 - Draw.width(shortcut), y: textY), color: fg) }
        } else if highlight {
            Draw.text(label.text, at: NSPoint(x: textX, y: textY), color: .gray, underline: label.mnemonicIndex)
        } else {
            Draw.embossedText(label.text, at: NSPoint(x: textX, y: textY), underline: label.mnemonicIndex)
            if let shortcut { Draw.embossedText(shortcut, at: NSPoint(x: r.maxX - 22 - Draw.width(shortcut), y: textY)) }
        }
        if submenu {
            PixelImages.draw(.submenuArrow, at: NSPoint(x: r.maxX - 12, y: r.minY + 5), glyphVariant)
        }
    }
}

/// A drop down list box, used for the address field's recent addresses.
final class ListPopupView: FaceView {
    let items: [String]
    var selected: Int? { didSet { if oldValue != selected { needsDisplay = true } } }
    static let rowHeight: CGFloat = 16

    init(items: [String]) {
        self.items = items
        super.init(frame: .zero)
        setAccessibilityRole(.list)
        setAccessibilityIdentifier("address-list")
    }

    required init?(coder: NSCoder) { fatalError() }

    func row(at p: NSPoint) -> Int? {
        let i = Int((p.y - 1) / Self.rowHeight)
        return items.indices.contains(i) && p.x >= 0 && p.x < bounds.width ? i : nil
    }

    override func draw(_ dirtyRect: NSRect) {
        Draw.crisp()
        Draw.fill(bounds, .white)
        Draw.hline(0, 0, bounds.width, .black)
        Draw.hline(0, bounds.height - 1, bounds.width, .black)
        Draw.vline(0, 0, bounds.height, .black)
        Draw.vline(bounds.width - 1, 0, bounds.height, .black)
        for (i, item) in items.enumerated() {
            let r = NSRect(x: 1, y: 1 + CGFloat(i) * Self.rowHeight, width: bounds.width - 2, height: Self.rowHeight)
            if i == selected { Draw.fill(r, .navy) }
            Draw.text(TitleBarView.truncate(item, width: r.width - 6, bold: false), at: NSPoint(x: r.minX + 3, y: r.minY), color: i == selected ? .white : .black)
        }
    }
}

/// Holds open menus above the window content. While anything is open it takes every click and
/// key: a click outside the menus closes them, like Windows.
final class MenuLayer: NSView {
    private(set) var levels: [PopupMenuView] = []
    private var list: ListPopupView?
    private var onPick: ((Int) -> Void)?
    private weak var bar: MenuBarView?
    private var barMenus: [Menu] = []
    private var previousResponder: NSResponder?
    private var tracking: NSTrackingArea?
    var onCommand: ((Command) -> Void)?

    override var isFlipped: Bool { true }
    var isOpen: Bool { !levels.isEmpty || list != nil }

    /// The Win95 id of what is open, for the control socket.
    var openDescription: String? {
        if let list { return "list:\(list.items.count)" }
        if let barIndex = bar?.openIndex, barMenus.indices.contains(barIndex) { return "menu:\(barMenus[barIndex].label.text):\(levels.count)" }
        return levels.isEmpty ? nil : "menu:popup:\(levels.count)"
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard isOpen else { return nil }
        return super.hitTest(point) ?? self
    }

    override var acceptsFirstResponder: Bool { isOpen }

    // MARK: opening

    func openBarMenu(_ index: Int, bar: MenuBarView, menus: [Menu], selectFirst: Bool = false) {
        closePopups()
        self.bar = bar
        barMenus = menus
        bar.openIndex = index
        let r = bar.itemRects()[index]
        let origin = convert(NSPoint(x: r.minX, y: r.maxY), from: bar)
        push(menus[index].entries, at: origin)
        if selectFirst { levels.last?.selected = MenuNavigation.next(from: nil, in: menus[index].entries, forward: true) }
        takeFocus()
    }

    func openMenu(_ entries: [MenuEntry], at origin: NSPoint) {
        close()
        push(entries, at: origin)
        takeFocus()
    }

    func openList(_ items: [String], below rect: NSRect, pick: @escaping (Int) -> Void) {
        close()
        guard !items.isEmpty else { return }
        let view = ListPopupView(items: items)
        let height = min(CGFloat(items.count), 12) * ListPopupView.rowHeight + 2
        view.frame = NSRect(x: rect.minX, y: rect.maxY, width: rect.width, height: height)
        addSubview(view)
        list = view
        onPick = pick
        takeFocus()
    }

    private func push(_ entries: [MenuEntry], at origin: NSPoint) {
        let view = PopupMenuView(entries: entries)
        let size = view.size
        var o = origin
        // Keep the panel inside the window, flipping left of its parent when needed.
        if o.x + size.width > bounds.width - 2 {
            if let parent = levels.last { o.x = parent.frame.minX - size.width + 3 } else { o.x = bounds.width - 2 - size.width }
        }
        o.x = max(o.x, 0)
        if o.y + size.height > bounds.height { o.y = max(bounds.height - size.height, 0) }
        view.frame = NSRect(origin: o, size: size)
        addSubview(view)
        levels.append(view)
    }

    private func takeFocus() {
        if previousResponder == nil { previousResponder = window?.firstResponder }
        window?.makeFirstResponder(self)
        updateTrackingAreas()
    }

    func close() {
        closePopups()
        bar?.openIndex = nil
        bar = nil
        if let previous = previousResponder, window?.firstResponder === self {
            window?.makeFirstResponder(previous)
        }
        previousResponder = nil
    }

    private func closePopups() {
        levels.forEach { $0.removeFromSuperview() }
        levels = []
        list?.removeFromSuperview()
        list = nil
        onPick = nil
    }

    private func popLevel() {
        levels.popLast()?.removeFromSuperview()
    }

    // MARK: mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseMoved(with event: NSEvent) {
        guard isOpen else { return }
        let p = convert(event.locationInWindow, from: nil)
        if let list {
            list.selected = list.row(at: convert(p, to: list))
            return
        }
        if let bar, let i = bar.index(at: convert(p, to: bar)), i != bar.openIndex {
            openBarMenu(i, bar: bar, menus: barMenus)
            return
        }
        for (depth, level) in levels.enumerated().reversed() {
            let lp = convert(p, to: level)
            guard level.bounds.contains(lp) else { continue }
            let row = level.row(at: lp)
            if row != level.selected {
                while levels.count > depth + 1 { popLevel() }
                level.selected = row.flatMap { level.entries[$0] == .separator ? nil : $0 }
                if let row, case let .submenu(menu) = level.entries[row], level.entries[row].isEnabled {
                    let r = level.rowRect(row)
                    push(menu.entries, at: convert(NSPoint(x: r.maxX + 1, y: r.minY - 3), from: level))
                }
            }
            return
        }
    }

    override func mouseDragged(with event: NSEvent) { mouseMoved(with: event) }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let bar, let i = bar.index(at: convert(p, to: bar)) {
            if i == bar.openIndex { close() } else { openBarMenu(i, bar: bar, menus: barMenus) }
            return
        }
        if let list, list.frame.contains(p) {
            if let row = list.row(at: convert(p, to: list)) { pick(row) }
            return
        }
        if levels.contains(where: { $0.frame.contains(p) }) { return }
        close()
    }

    override func mouseUp(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        for level in levels.reversed() where level.frame.contains(p) {
            if let row = level.row(at: convert(p, to: level)) { activate(level, row) }
            return
        }
    }

    override func rightMouseDown(with event: NSEvent) { close() }

    private func pick(_ row: Int) {
        let action = onPick
        close()
        action?(row)
    }

    private func activate(_ level: PopupMenuView, _ row: Int) {
        switch level.entries[row] {
        case let .item(item) where item.isEnabled:
            close()
            onCommand?(item.command)
        case let .submenu(menu) where level.entries[row].isEnabled:
            if levels.last !== level {
                return
            }
            level.selected = row
            let r = level.rowRect(row)
            push(menu.entries, at: convert(NSPoint(x: r.maxX + 1, y: r.minY - 3), from: level))
            levels.last?.selected = MenuNavigation.next(from: nil, in: menu.entries, forward: true)
        default:
            break
        }
    }

    // MARK: keys

    override func keyDown(with event: NSEvent) {
        if let list {
            switch event.keyCode {
            case 125: list.selected = min((list.selected ?? -1) + 1, list.items.count - 1)
            case 126: list.selected = max((list.selected ?? 1) - 1, 0)
            case 36, 76: if let s = list.selected { pick(s) } else { close() }
            case 53: close()
            default: break
            }
            return
        }
        guard let level = levels.last else { return }
        switch event.keyCode {
        case 125: level.selected = MenuNavigation.next(from: level.selected, in: level.entries, forward: true)
        case 126: level.selected = MenuNavigation.next(from: level.selected, in: level.entries, forward: false)
        case 124:
            if let s = level.selected, case .submenu = level.entries[s] {
                activate(level, s)
            } else {
                moveAcrossBar(1)
            }
        case 123:
            if levels.count > 1 { popLevel() } else { moveAcrossBar(-1) }
        case 36, 76:
            if let s = level.selected { activate(level, s) }
        case 53:
            if levels.count > 1 { popLevel() } else { close() }
        default:
            if let c = event.charactersIgnoringModifiers?.first, let row = MenuNavigation.mnemonic(c, in: level.entries) {
                level.selected = row
                activate(level, row)
            }
        }
    }

    private func moveAcrossBar(_ delta: Int) {
        guard let bar, let i = bar.openIndex, !barMenus.isEmpty else { return }
        openBarMenu((i + delta + barMenus.count) % barMenus.count, bar: bar, menus: barMenus, selectFirst: true)
    }

    /// For the control socket: press the row labelled `text` in the deepest open menu.
    func pressRow(_ text: String) -> Bool {
        guard let level = levels.last, let row = level.entries.firstIndex(where: { $0.label?.text == text }) else { return false }
        activate(level, row)
        return true
    }
}
