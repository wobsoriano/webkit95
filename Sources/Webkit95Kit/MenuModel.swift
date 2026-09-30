import Foundation

/// Everything a menu item, a toolbar button or a keyboard shortcut can ask a window to do.
public enum Command: Hashable, Sendable {
    case newWindow, print, close
    case cut, copy, paste, selectAll, find
    case toggleToolbar, toggleAddressBar, toggleStatusBar, toggleAssistant
    case textSize(TextSize), textLarger, textSmaller, textReset
    case stop, refresh, viewSource
    case back, forward, home, search, focusAddress
    case addFavorite, openFavorite(String), removeFavorite(String)
    case about
    /// Row n of the web page's own context menu, which webkit95 redraws as a Win95 menu.
    case contextItem(Int)

    /// Stable ids for the control socket and the macOS menu. Favorites carry their URL.
    public var id: String {
        switch self {
        case .newWindow: "file.newWindow"
        case .print: "file.print"
        case .close: "file.close"
        case .cut: "edit.cut"
        case .copy: "edit.copy"
        case .paste: "edit.paste"
        case .selectAll: "edit.selectAll"
        case .find: "edit.find"
        case .toggleToolbar: "view.toolbar"
        case .toggleAddressBar: "view.addressBar"
        case .toggleStatusBar: "view.statusBar"
        case .toggleAssistant: "view.assistant"
        case let .textSize(size): "view.textSize.\(size.title.lowercased())"
        case .textLarger: "view.textLarger"
        case .textSmaller: "view.textSmaller"
        case .textReset: "view.textReset"
        case .stop: "view.stop"
        case .refresh: "view.refresh"
        case .viewSource: "view.source"
        case .back: "go.back"
        case .forward: "go.forward"
        case .home: "go.home"
        case .search: "go.search"
        case .focusAddress: "go.address"
        case .addFavorite: "favorites.add"
        case let .openFavorite(url): "favorites.open \(url)"
        case let .removeFavorite(url): "favorites.remove \(url)"
        case .about: "help.about"
        case let .contextItem(n): "context.\(n)"
        }
    }

    public init?(id: String) {
        if id.hasPrefix("favorites.open ") { self = .openFavorite(String(id.dropFirst("favorites.open ".count))); return }
        if id.hasPrefix("favorites.remove ") { self = .removeFavorite(String(id.dropFirst("favorites.remove ".count))); return }
        if id.hasPrefix("context."), let n = Int(id.dropFirst("context.".count)) { self = .contextItem(n); return }
        guard let match = Self.fixed.first(where: { $0.id == id }) else { return nil }
        self = match
    }

    static let fixed: [Command] = [
        .newWindow, .print, .close, .cut, .copy, .paste, .selectAll, .find,
        .toggleToolbar, .toggleAddressBar, .toggleStatusBar, .toggleAssistant,
        .textLarger, .textSmaller, .textReset, .stop, .refresh, .viewSource,
        .back, .forward, .home, .search, .focusAddress, .addFavorite, .about,
    ] + TextSize.allCases.map { .textSize($0) }
}

public struct Modifiers: OptionSet, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let command = Modifiers(rawValue: 1)
    public static let shift = Modifiers(rawValue: 2)
    public static let option = Modifiers(rawValue: 4)
    public static let control = Modifiers(rawValue: 8)
}

public enum Key: Hashable, Sendable {
    /// A printable key as the unmodified character it types ("n", "[", "=").
    case character(Character)
    case escape
    case f5
}

public struct Shortcut: Hashable, Sendable {
    public let key: Key
    public let modifiers: Modifiers

    public init(_ key: Key, _ modifiers: Modifiers = []) {
        self.key = key
        self.modifiers = modifiers
    }

    public static func cmd(_ c: Character) -> Shortcut { Shortcut(.character(c), .command) }

    /// The text at the right edge of a menu row.
    public var display: String {
        var parts: [String] = []
        if modifiers.contains(.control) { parts.append("Ctrl") }
        if modifiers.contains(.option) { parts.append("Opt") }
        if modifiers.contains(.shift) { parts.append("Shift") }
        if modifiers.contains(.command) { parts.append("Cmd") }
        switch key {
        case let .character(c): parts.append(c == "=" ? "+" : String(c).uppercased())
        case .escape: parts.append("Esc")
        case .f5: parts.append("F5")
        }
        return parts.joined(separator: "+")
    }
}

/// Menu text with a Windows style mnemonic: "&File" shows "File" with the F underlined.
public struct MenuLabel: Equatable, Sendable {
    public let text: String
    /// Index into `text` of the underlined character.
    public let mnemonicIndex: Int?

    public init(_ marked: String) {
        var text = ""
        var index: Int?
        var chars = marked.makeIterator()
        while let c = chars.next() {
            if c == "&", let next = chars.next() {
                if next != "&" && index == nil { index = text.count }
                text.append(next)
            } else {
                text.append(c)
            }
        }
        self.text = text
        self.mnemonicIndex = index
    }

    public var mnemonic: Character? {
        mnemonicIndex.map { Character(text[text.index(text.startIndex, offsetBy: $0)].lowercased()) }
    }
}

public enum MenuCheck: Equatable, Sendable {
    case none, check, radio
}

public struct MenuItem: Equatable, Sendable {
    public let command: Command
    public let label: MenuLabel
    public let shortcut: Shortcut?
    public let isEnabled: Bool
    public let check: MenuCheck
    /// A small icon in the check column, for favorites rows.
    public let icon: Icon?

    public init(command: Command, label: MenuLabel, shortcut: Shortcut?, isEnabled: Bool, check: MenuCheck, icon: Icon? = nil) {
        self.command = command
        self.label = label
        self.shortcut = shortcut
        self.isEnabled = isEnabled
        self.check = check
        self.icon = icon
    }
}

public indirect enum MenuEntry: Equatable, Sendable {
    case item(MenuItem)
    case separator
    case submenu(Menu)

    public var label: MenuLabel? {
        switch self {
        case let .item(item): item.label
        case let .submenu(menu): menu.label
        case .separator: nil
        }
    }

    public var isEnabled: Bool {
        switch self {
        case let .item(item): item.isEnabled
        case let .submenu(menu): menu.entries.contains { $0.isEnabled }
        case .separator: false
        }
    }
}

public struct Menu: Equatable, Sendable {
    public let label: MenuLabel
    public let entries: [MenuEntry]

    public init(label: MenuLabel, entries: [MenuEntry]) {
        self.label = label
        self.entries = entries
    }
}

/// What the menus need to know about the window they act on.
public struct MenuContext: Equatable, Sendable {
    public var state: BrowserWindowState
    public var favorites: [Favorite]
    /// A dialog is up; only commands that make sense beside it stay enabled.
    public var modal: Bool

    public init(state: BrowserWindowState, favorites: [Favorite], modal: Bool = false) {
        self.state = state
        self.favorites = favorites
        self.modal = modal
    }
}

/// The in window Windows 95 menu bar and the macOS menu bar both come from this one table.
public enum MenuModel {
    public static func menus(_ ctx: MenuContext) -> [Menu] {
        let s = ctx.state
        let page = s.url != nil && !ctx.modal
        let free = !ctx.modal
        func item(_ label: String, _ command: Command, _ shortcut: Shortcut? = nil, enabled: Bool = true, check: MenuCheck = .none, icon: Icon? = nil) -> MenuEntry {
            .item(MenuItem(command: command, label: MenuLabel(label), shortcut: shortcut ?? primaryShortcut[command], isEnabled: enabled && free, check: check, icon: icon))
        }
        func checked(_ on: Bool) -> MenuCheck { on ? .check : .none }

        let file = Menu(label: MenuLabel("&File"), entries: [
            item("&New Window", .newWindow),
            .separator,
            item("&Print...", .print, enabled: page),
            .separator,
            item("&Close", .close),
        ])
        let edit = Menu(label: MenuLabel("&Edit"), entries: [
            item("Cu&t", .cut),
            item("&Copy", .copy),
            item("&Paste", .paste),
            .separator,
            item("Select &All", .selectAll),
            .separator,
            item("&Find (on this page)...", .find, enabled: page),
        ])
        let sizes = TextSize.allCases.reversed().map { size in
            item("&" + size.title, .textSize(size), check: s.textSize == size ? .radio : .none)
        }
        let view = Menu(label: MenuLabel("&View"), entries: [
            item("&Toolbar", .toggleToolbar, check: checked(s.toolbarVisible)),
            item("&Address Bar", .toggleAddressBar, check: checked(s.addressBarVisible)),
            item("Status &Bar", .toggleStatusBar, check: checked(s.statusBarVisible)),
            .submenu(Menu(label: MenuLabel("&Explorer Bar"), entries: [
                item("&Assistant", .toggleAssistant, check: checked(s.assistantOpen)),
            ])),
            .separator,
            .submenu(Menu(label: MenuLabel("Text Si&ze"), entries: sizes)),
            .separator,
            item("Sto&p", .stop, enabled: s.isLoading),
            item("&Refresh", .refresh, enabled: page),
            .separator,
            item("Sour&ce", .viewSource, enabled: page),
        ])
        let go = Menu(label: MenuLabel("&Go"), entries: [
            item("&Back", .back, enabled: s.canGoBack),
            item("&Forward", .forward, enabled: s.canGoForward),
            .separator,
            item("&Home Page", .home),
            item("&Search the Web", .search),
        ])
        var favoriteEntries: [MenuEntry] = [
            item("&Add to Favorites...", .addFavorite, enabled: page),
            .submenu(Menu(label: MenuLabel("&Remove"), entries: ctx.favorites.map {
                item(escaped($0.title), .removeFavorite($0.url))
            })),
        ]
        if !ctx.favorites.isEmpty { favoriteEntries.append(.separator) }
        favoriteEntries += ctx.favorites.map { item(escaped($0.title), .openFavorite($0.url), icon: .favoriteItem) }
        let favorites = Menu(label: MenuLabel("F&avorites"), entries: favoriteEntries)
        let help = Menu(label: MenuLabel("&Help"), entries: [
            item("&About webkit95", .about),
        ])
        return [file, edit, view, go, favorites, help]
    }

    /// The shortcut shown in menus, one per command.
    public static let primaryShortcut: [Command: Shortcut] = [
        .newWindow: .cmd("n"),
        .print: .cmd("p"),
        .close: .cmd("w"),
        .cut: .cmd("x"),
        .copy: .cmd("c"),
        .paste: .cmd("v"),
        .selectAll: .cmd("a"),
        .find: .cmd("f"),
        .toggleAssistant: Shortcut(.character("a"), [.command, .shift]),
        .stop: Shortcut(.escape),
        .refresh: .cmd("r"),
        .viewSource: Shortcut(.character("u"), [.command, .option]),
        .back: .cmd("["),
        .forward: .cmd("]"),
        .focusAddress: .cmd("l"),
        .addFavorite: .cmd("d"),
    ]

    /// Every key that runs a command, the primary shortcuts plus the alternates.
    public static let shortcuts: [Shortcut: Command] = {
        var map: [Shortcut: Command] = [:]
        for (command, shortcut) in primaryShortcut { map[shortcut] = command }
        map[Shortcut(.f5)] = .refresh
        map[.cmd("=")] = .textLarger
        map[Shortcut(.character("="), [.command, .shift])] = .textLarger
        map[.cmd("+")] = .textLarger
        map[.cmd("-")] = .textSmaller
        map[.cmd("0")] = .textReset
        return map
    }()

    public static func command(for shortcut: Shortcut) -> Command? { shortcuts[shortcut] }

    /// Every enabled command in the table, for the control socket's `press`.
    public static func enabledCommands(_ ctx: MenuContext) -> [Command] {
        items(ctx).filter(\.isEnabled).map(\.command)
    }

    /// A command with a menu row follows that row; one with only a shortcut (Cmd+L, Cmd+plus)
    /// works whenever no dialog is up.
    public static func isEnabled(_ command: Command, _ ctx: MenuContext) -> Bool {
        if let row = items(ctx).first(where: { $0.command == command }) { return row.isEnabled }
        return !ctx.modal
    }

    /// Shortcuts whose command has no menu row, so the macOS menu bar must carry them hidden.
    public static func shortcutsWithoutRows(_ ctx: MenuContext) -> [(Shortcut, Command)] {
        let rows = Set(items(ctx).compactMap { $0.shortcut })
        return shortcuts.filter { !rows.contains($0.key) }.map { ($0.key, $0.value) }.sorted { $0.1.id < $1.1.id }
    }

    private static func items(_ ctx: MenuContext) -> [MenuItem] {
        func walk(_ entries: [MenuEntry]) -> [MenuItem] {
            entries.flatMap { entry -> [MenuItem] in
                switch entry {
                case let .item(item): [item]
                case let .submenu(menu): walk(menu.entries)
                case .separator: []
                }
            }
        }
        return menus(ctx).flatMap { walk($0.entries) }
    }

    private static func escaped(_ title: String) -> String {
        title.replacingOccurrences(of: "&", with: "&&")
    }
}

/// Keyboard movement through an open menu: skips separators and disabled rows, wraps around.
public enum MenuNavigation {
    public static func next(from index: Int?, in entries: [MenuEntry], forward: Bool) -> Int? {
        let selectable = entries.indices.filter { entries[$0].isEnabled }
        guard !selectable.isEmpty else { return nil }
        guard let index else { return forward ? selectable.first : selectable.last }
        if forward { return selectable.first { $0 > index } ?? selectable.first }
        return selectable.last { $0 < index } ?? selectable.last
    }

    /// The row whose mnemonic is `key`, enabled only.
    public static func mnemonic(_ key: Character, in entries: [MenuEntry]) -> Int? {
        let key = Character(key.lowercased())
        return entries.indices.first { entries[$0].isEnabled && entries[$0].label?.mnemonic == key }
    }
}
