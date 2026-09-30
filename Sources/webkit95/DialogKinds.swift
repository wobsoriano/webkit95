import AppKit
import Webkit95Kit

/// The specific Win95 dialogs, built on `DialogView`.
@MainActor
enum Dialogs {
    static func prompt(title: String, message: String, text: String, done: @escaping (String?) -> Void) -> DialogView {
        let width: CGFloat = 360
        let lines = Draw.wrap(message, width: width - 24 - 90)
        let textH = max(CGFloat(lines.count) * Fonts.lineHeight, 16)
        let height = 12 + max(textH, 46) + 10 + 22 + 12
        let d = DialogView(kind: "prompt", title: title, size: NSSize(width: width, height: height))
        let label = Win95Label(message)
        label.wraps = true
        label.frame = NSRect(x: 12, y: 12, width: width - 24 - 90, height: textH)
        d.body.addSubview(label)
        let field = SunkenField(text: text)
        field.frame = NSRect(x: 12, y: height - 12 - 22, width: width - 24, height: 22)
        d.body.addSubview(field)
        d.addButton("ok", "OK", frame: NSRect(x: width - 12 - 75, y: 12, width: 75, height: 23)) { [weak d] in
            d?.close(); done(field.field.stringValue)
        }
        d.addButton("cancel", "Cancel", frame: NSRect(x: width - 12 - 75, y: 12 + 23 + 6, width: 75, height: 23)) { [weak d] in
            d?.close(); done(nil)
        }
        d.register(.field("text"), field)
        d.setFocusOrder([.field("text"), .button("ok"), .button("cancel")], defaultButton: "ok", cancelButton: "cancel", initial: .field("text"))
        return d
    }

    static func addFavorite(title: String, done: @escaping (String?) -> Void) -> DialogView {
        let width: CGFloat = 380, height: CGFloat = 112
        let d = DialogView(kind: "favorite", title: "Add to Favorites", size: NSSize(width: width, height: height))
        let icon = IconView(icon: .favorites)
        icon.frame = NSRect(x: 12, y: 12, width: 20, height: 20)
        d.body.addSubview(icon)
        let msg = Win95Label("webkit95 will add this page to your Favorites list.")
        msg.wraps = true
        msg.frame = NSRect(x: 44, y: 12, width: width - 44 - 12 - 87, height: 32)
        d.body.addSubview(msg)
        let nameLabel = Win95Label("&Name:")
        nameLabel.frame = NSRect(x: 12, y: 70, width: 44, height: 22)
        d.body.addSubview(nameLabel)
        let field = SunkenField(text: title)
        field.frame = NSRect(x: 56, y: 70, width: width - 56 - 12, height: 22)
        d.body.addSubview(field)
        d.addButton("ok", "OK", frame: NSRect(x: width - 12 - 75, y: 10, width: 75, height: 23)) { [weak d] in
            d?.close(); done(field.field.stringValue)
        }
        d.addButton("cancel", "Cancel", frame: NSRect(x: width - 12 - 75, y: 10 + 23 + 6, width: 75, height: 23)) { [weak d] in
            d?.close(); done(nil)
        }
        d.register(.field("name"), field)
        d.setFocusOrder([.field("name"), .button("ok"), .button("cancel")], defaultButton: "ok", cancelButton: "cancel", initial: .field("name"))
        return d
    }

    static func about() -> DialogView {
        let width: CGFloat = 360, height: CGFloat = 200
        let d = DialogView(kind: "about", title: "About webkit95", size: NSSize(width: width, height: height))
        let logo = LogoBadge()
        logo.frame = NSRect(x: 12, y: 12, width: 72, height: 72)
        d.body.addSubview(logo)
        let lines: [(String, Bool)] = [
            ("webkit95", true),
            ("Version 0.1 (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "dev"))", false),
            ("A WebKit browser dressed for 1996.", false),
            ("", false),
            ("This is an homage, not affiliated with", false),
            ("Microsoft. All art is original.", false),
            ("Font: Ark Pixel by TakWolf (OFL 1.1).", false),
        ]
        for (i, line) in lines.enumerated() {
            let l = Win95Label(line.0)
            l.bold = line.1
            l.frame = NSRect(x: 96, y: 12 + CGFloat(i) * 16, width: width - 96 - 12, height: 16)
            d.body.addSubview(l)
        }
        let sep = EtchedLine()
        sep.frame = NSRect(x: 12, y: height - 23 - 22, width: width - 24, height: 2)
        d.body.addSubview(sep)
        d.addButton("ok", "OK", frame: NSRect(x: width - 12 - 75, y: height - 23 - 12, width: 75, height: 23)) { [weak d] in d?.close() }
        d.setFocusOrder([.button("ok")], defaultButton: "ok", cancelButton: "ok")
        return d
    }

    static func find(state: FindState, next: @escaping (FindState) -> Void, close: @escaping (FindState) -> Void) -> DialogView {
        let width: CGFloat = 356, height: CGFloat = 92
        let d = DialogView(kind: "find", title: "Find", modal: false, size: NSSize(width: width, height: height))
        let label = Win95Label("Fi&nd what:")
        label.frame = NSRect(x: 8, y: 12, width: 64, height: 20)
        d.body.addSubview(label)
        let field = SunkenField(text: state.query)
        field.frame = NSRect(x: 72, y: 11, width: 186, height: 22)
        d.body.addSubview(field)
        let matchCase = Win95Checkbox("Match &case", isOn: state.matchCase)
        matchCase.frame = NSRect(x: 8, y: 62, width: 110, height: 18)
        d.body.addSubview(matchCase)
        let group = Win95GroupBox("Direction")
        group.frame = NSRect(x: 132, y: 40, width: 126, height: 44)
        d.body.addSubview(group)
        let up = Win95Radio("&Up", isOn: !state.searchDown)
        let down = Win95Radio("&Down", isOn: state.searchDown)
        up.frame = NSRect(x: 142, y: 60, width: 50, height: 18)
        down.frame = NSRect(x: 194, y: 60, width: 58, height: 18)
        d.body.addSubview(up)
        d.body.addSubview(down)
        up.onSelect = { [weak d, weak up, weak down] in up?.isOn = true; down?.isOn = false; d?.focus.focus(.radio("up")); d?.syncFocus() }
        down.onSelect = { [weak d, weak up, weak down] in down?.isOn = true; up?.isOn = false; d?.focus.focus(.radio("down")); d?.syncFocus() }
        func current() -> FindState {
            var f = state
            f.query = field.field.stringValue
            f.matchCase = matchCase.isOn
            f.searchDown = down.isOn
            return f
        }
        d.addButton("next", "&Find Next", frame: NSRect(x: width - 8 - 80, y: 10, width: 80, height: 23)) { next(current()) }
        d.addButton("cancel", "Cancel", frame: NSRect(x: width - 8 - 80, y: 10 + 23 + 6, width: 80, height: 23)) { [weak d] in
            d?.close(); close(current())
        }
        d.register(.field("query"), field)
        d.register(.checkbox("case"), matchCase)
        d.register(.radio("up"), up)
        d.register(.radio("down"), down)
        d.setFocusOrder([.field("query"), .checkbox("case"), .radio("up"), .radio("down"), .button("next"), .button("cancel")],
                        defaultButton: "next", cancelButton: "cancel", initial: .field("query"))
        return d
    }
}

/// The app icon at 2x in a sunken well, for the About box.
final class LogoBadge: FaceView {
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let inner = Draw.bevel(.sunkenField, bounds)
        Draw.fill(inner, .teal)
        let art = Icon.app32.art
        PixelImages.draw(art, at: NSPoint(x: inner.midX - CGFloat(art.width), y: inner.midY - CGFloat(art.height)), scale: 2)
    }
}

final class EtchedLine: FaceView {
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        Draw.etched(horizontal: bounds.width >= bounds.height, at: .zero, length: max(bounds.width, bounds.height))
    }
}
