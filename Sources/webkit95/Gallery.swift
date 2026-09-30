#if DEBUG
import AppKit
import Webkit95Kit

/// A window showing every Win95 component, for screenshots (control command `gallery`).
@MainActor
enum Gallery {
    static var window: Win95Window?

    static func open() -> Win95Window {
        let w = Win95Window(contentRect: NSRect(x: 80, y: 80, width: 640, height: 470))
        let frame = WindowFrameView()
        w.contentView = frame
        w.title = "webkit95 component gallery"
        frame.titleBar.title = "Component Gallery"
        frame.titleBar.isActive = true
        let c = frame.content
        func add(_ v: NSView, _ r: NSRect) { v.frame = r; c.addSubview(v) }

        let bevels: [(String, Bevel)] = [("raised", .raisedButton), ("pressed", .pressedButton), ("window", .windowFrame),
                                         ("sunken", .sunkenField), ("thin up", .thinRaised), ("thin in", .thinSunken), ("groove", .groove)]
        for (i, b) in bevels.enumerated() {
            add(BevelSample(b.1, b.0), NSRect(x: 8 + i * 88, y: 8, width: 80, height: 40))
        }
        let normal = Win95Button("&Normal")
        add(normal, NSRect(x: 8, y: 60, width: 75, height: 23))
        let def = Win95Button("&Default")
        def.isDefault = true
        def.hasFocusRing = true
        add(def, NSRect(x: 90, y: 60, width: 75, height: 23))
        let disabled = Win95Button("Disa&bled")
        disabled.isEnabled = false
        add(disabled, NSRect(x: 172, y: 60, width: 75, height: 23))
        let tool = Win95Button("Home", style: .toolbar, icon: .home)
        add(tool, NSRect(x: 260, y: 52, width: 54, height: 42))
        let toolOff = Win95Button("Back", style: .toolbar, icon: .back)
        toolOff.isEnabled = false
        add(toolOff, NSRect(x: 318, y: 52, width: 54, height: 42))
        let latched = Win95Button("Assistant", style: .toolbar, icon: .assistant)
        latched.isLatched = true
        add(latched, NSRect(x: 376, y: 52, width: 64, height: 42))
        for (i, icon) in [Icon.minimize, .maximize, .restore, .close].enumerated() {
            add(Win95Button("", style: .titleBar, icon: icon), NSRect(x: 452 + i * 18, y: 60, width: 16, height: 14))
        }

        let check = Win95Checkbox("Include current &page", isOn: true)
        check.hasFocusRing = true
        add(check, NSRect(x: 8, y: 100, width: 160, height: 18))
        add(Win95Checkbox("Match &case", isOn: false), NSRect(x: 8, y: 122, width: 160, height: 18))
        let group = Win95GroupBox("Direction")
        add(group, NSRect(x: 180, y: 96, width: 140, height: 48))
        add(Win95Radio("&Up", isOn: false), NSRect(x: 190, y: 118, width: 50, height: 18))
        add(Win95Radio("&Down", isOn: true), NSRect(x: 250, y: 118, width: 60, height: 18))
        let field = SunkenField(text: "http://www.example.com/")
        add(field, NSRect(x: 336, y: 100, width: 200, height: 22))
        let progress = Win95Progress()
        progress.fraction = 0.6
        progress.sunken = .sunkenField
        add(progress, NSRect(x: 336, y: 128, width: 200, height: 16))

        let scroll = Win95ScrollView()
        let text = PixelTextView()
        PixelTextView.configure(text)
        text.string = (1...40).map { "Line \($0) of a scrolling text box with a Windows 95 scrollbar." }.joined(separator: "\n")
        text.isEditable = false
        text.drawsBackground = true
        text.backgroundColor = .white
        text.isVerticallyResizable = true
        text.textContainer?.widthTracksTextView = true
        scroll.documentView = text
        add(scroll, NSRect(x: 8, y: 156, width: 300, height: 120))
        text.frame = NSRect(x: 0, y: 0, width: scroll.scrollView.contentSize.width, height: 10)
        text.sizeToFit()
        scroll.sync()

        let menu = PopupMenuView(entries: MenuModel.menus(MenuContext(state: {
            var s = BrowserWindowState(); s.url = URL(string: "https://example.com"); s.isLoading = true; return s
        }(), favorites: Favorites.defaults))[2].entries)
        menu.selected = 3
        add(menu, NSRect(origin: NSPoint(x: 320, y: 156), size: menu.size))

        let sheet = IconSheet()
        add(sheet, NSRect(x: 8, y: 286, width: 300, height: 150))
        w.orderFront(nil)
        window = w
        return w
    }
}

private final class BevelSample: FaceView {
    let bevel: Bevel
    let name: String
    init(_ bevel: Bevel, _ name: String) {
        self.bevel = bevel
        self.name = name
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        Draw.bevel(bevel, bounds)
        Draw.text(name, at: NSPoint(x: 8, y: 12))
    }
}

private final class IconSheet: FaceView {
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0
        for icon in Icon.allCases {
            let a = icon.art
            if x + CGFloat(a.width) > bounds.width { x = 0; y += rowH + 4; rowH = 0 }
            PixelImages.draw(icon, at: NSPoint(x: x, y: y))
            x += CGFloat(a.width) + 4
            rowH = max(rowH, CGFloat(a.height))
        }
    }
}
#endif
