import Foundation
import Testing
@testable import Webkit95Kit

@Suite struct URLInputTests {
    @Test(arguments: [
        ("https://example.com/a?b", "https://example.com/a?b"),
        ("example.com", "https://example.com"),
        ("news.ycombinator.com/item?id=1", "https://news.ycombinator.com/item?id=1"),
        ("localhost:8080/x", "http://localhost:8080/x"),
        ("127.0.0.1:9000", "http://127.0.0.1:9000"),
        ("10.0.0.1", "https://10.0.0.1"),
        ("about:blank", "about:blank"),
        ("webkit95://home/", "webkit95://home/"),
        ("", "about:blank"),
        ("  example.org  ", "https://example.org"),
    ])
    func resolves(input: String, expected: String) {
        #expect(URLInput.resolve(input).absoluteString == expected)
    }

    @Test(arguments: ["hello world", "swift", "what is a.b c", ".com", "trailing."])
    func searches(input: String) {
        #expect(URLInput.resolve(input).absoluteString.hasPrefix("https://duckduckgo.com/?q="))
    }

    @Test func encodesQuery() {
        #expect(URLInput.resolve("a&b c").absoluteString == "https://duckduckgo.com/?q=a%26b%20c")
    }
}

@Suite struct StoreTests {
    @Test func historyIsMostRecentFirstWithoutDuplicates() {
        var h = AddressHistory()
        h.record("a.com")
        h.record("b.com")
        h.record("a.com")
        h.record("  ")
        #expect(h.entries == ["a.com", "b.com"])
    }

    @Test func historyCapsAt25() {
        var h = AddressHistory()
        for i in 0..<40 { h.record("site\(i).com") }
        #expect(h.entries.count == 25)
        #expect(h.entries.first == "site39.com")
    }

    @Test func historyRoundTripsThroughAFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = JSONFile<AddressHistory>(dir.appendingPathComponent("history.json"))
        #expect(file.load() == nil)
        var h = AddressHistory()
        h.record("one.com")
        h.record("two.com")
        try file.save(h)
        #expect(file.load() == h)
    }

    @Test func favoritesDefaultsAndEdits() {
        var f = Favorites()
        #expect(f.items.map(\.title) == ["Wikipedia", "Hacker News", "DuckDuckGo", "Apple", "GitHub"])
        f.add(title: "Example\nPage", url: "https://example.com/")
        f.add(title: "Renamed", url: "https://example.com/")
        #expect(f.items.last == Favorite(title: "Renamed", url: "https://example.com/"))
        #expect(f.items.count == 6)
        f.add(title: "", url: "https://blank.example/")
        #expect(f.items.last?.title == "https://blank.example/")
        f.remove(url: "https://example.com/")
        #expect(!f.items.contains { $0.url == "https://example.com/" })
    }

    @Test func emptyFavoritesStayEmptyAfterReload() throws {
        let data = try JSONEncoder().encode(Favorites(items: []))
        #expect(try JSONDecoder().decode(Favorites.self, from: data).items.isEmpty)
    }

    @Test func supportDirectoryHonorsOverride() {
        #expect(SupportDirectory.resolve(environment: ["WEBKIT95_SUPPORT_DIR": "/tmp/x"]).path == "/tmp/x")
        #expect(SupportDirectory.resolve(environment: [:]).path.hasSuffix("Application Support/webkit95"))
    }
}

@Suite struct DownloadNamingTests {
    @Test(arguments: [
        ("report.pdf", "report.pdf"),
        ("../../etc/passwd", "_.._etc_passwd"),
        (".hidden", "hidden"),
        ("...", "download"),
        ("", "download"),
        ("a/b\\c:d", "a_b_c_d"),
        ("line\nbreak\u{0}.txt", "line_break_.txt"),
        ("  spaced.zip  ", "spaced.zip"),
        ("/", "download"),
    ])
    func safeNames(input: String, expected: String) {
        #expect(DownloadNaming.safeName(input) == expected)
    }

    @Test func capsLengthKeepingExtension() {
        let name = DownloadNaming.safeName(String(repeating: "é", count: 300) + ".tar.gz")
        #expect(name.utf8.count <= DownloadNaming.byteLimit)
        #expect(name.hasSuffix(".gz"))
    }

    @Test func uniqueNeverReusesATakenName() {
        let dir = URL(fileURLWithPath: "/d")
        let taken: Set<String> = ["/d/file.txt", "/d/file (2).txt"]
        #expect(DownloadNaming.unique("file.txt", in: dir, exists: { taken.contains($0.path) }).path == "/d/file (3).txt")
        #expect(DownloadNaming.unique("new.txt", in: dir, exists: { taken.contains($0.path) }).path == "/d/new.txt")
        #expect(DownloadNaming.unique("noext", in: dir, exists: { $0.lastPathComponent == "noext" }).lastPathComponent == "noext (2)")
    }
}

@Suite struct WindowStateTests {
    @Test func titleFallsBackToAddressThenAppName() {
        var s = BrowserWindowState()
        #expect(s.windowTitle == "webkit95")
        s.url = URL(string: "https://example.com/")
        #expect(s.windowTitle == "webkit95 - https://example.com/")
        s.title = "Example"
        #expect(s.windowTitle == "webkit95 - Example")
    }

    @Test func textSizeStepsAndClamps() {
        #expect(TextSize.medium.stepUp == .larger)
        #expect(TextSize.largest.stepUp == .largest)
        #expect(TextSize.smallest.stepDown == .smallest)
        #expect(TextSize.allCases.map(\.pageZoom) == TextSize.allCases.map(\.pageZoom).sorted())
    }

    @Test func zones() {
        #expect(SecurityZone.of(URL(string: "https://a.com")) == .internet)
        #expect(SecurityZone.of(URL(string: "http://127.0.0.1:8000")) == .localIntranet)
        #expect(SecurityZone.of(URL(string: "webkit95://home/")) == .myComputer)
    }

    @Test func assistantWidthClamps() {
        var s = BrowserWindowState()
        s.setAssistantWidth(20)
        #expect(s.assistantWidth == 160)
        s.setAssistantWidth(9000)
        #expect(s.assistantWidth == 520)
    }
}

@Suite struct MenuModelTests {
    func ctx(_ change: (inout BrowserWindowState) -> Void = { _ in }) -> MenuContext {
        var s = BrowserWindowState()
        s.url = URL(string: "https://example.com")
        change(&s)
        return MenuContext(state: s, favorites: Favorites.defaults)
    }

    func item(_ menus: [Menu], _ command: Command) -> MenuItem? {
        func walk(_ entries: [MenuEntry]) -> MenuItem? {
            for e in entries {
                switch e {
                case let .item(i) where i.command == command: return i
                case let .submenu(m): if let found = walk(m.entries) { return found }
                default: continue
                }
            }
            return nil
        }
        return menus.lazy.compactMap { walk($0.entries) }.first
    }

    @Test func menuBarTitlesAndMnemonics() {
        let menus = MenuModel.menus(ctx())
        #expect(menus.map(\.label.text) == ["File", "Edit", "View", "Go", "Favorites", "Help"])
        #expect(menus.map(\.label.mnemonic) == ["f", "e", "v", "g", "a", "h"])
    }

    @Test func enabledStateFollowsTheWindow() {
        let idle = MenuModel.menus(ctx())
        #expect(item(idle, .back)?.isEnabled == false)
        #expect(item(idle, .stop)?.isEnabled == false)
        let busy = MenuModel.menus(ctx { $0.canGoBack = true; $0.isLoading = true })
        #expect(item(busy, .back)?.isEnabled == true)
        #expect(item(busy, .stop)?.isEnabled == true)
    }

    @Test func checksAndRadios() {
        let menus = MenuModel.menus(ctx { $0.statusBarVisible = false; $0.textSize = .larger })
        #expect(item(menus, .toggleToolbar)?.check == .check)
        #expect(item(menus, .toggleStatusBar)?.check == MenuCheck.none)
        #expect(item(menus, .textSize(.larger))?.check == .radio)
        #expect(item(menus, .textSize(.medium))?.check == MenuCheck.none)
    }

    @Test func modalDisablesEverything() {
        var c = ctx()
        c.modal = true
        #expect(MenuModel.enabledCommands(c).isEmpty)
    }

    @Test func favoritesAppearWithEscapedAmpersands() {
        var c = ctx()
        c.favorites = [Favorite(title: "Tom & Jerry", url: "https://tj.example/")]
        let fav = MenuModel.menus(c)[4]
        guard case let .item(row) = fav.entries.last else { Issue.record("no favorite row"); return }
        #expect(row.label.text == "Tom & Jerry")
        #expect(row.command == .openFavorite("https://tj.example/"))
    }

    @Test func everyCommandIDRoundTrips() {
        for command in MenuModel.enabledCommands(ctx { $0.isLoading = true; $0.canGoBack = true; $0.canGoForward = true }) {
            #expect(Command(id: command.id) == command, "\(command.id)")
        }
    }

    @Test func shortcutsIncludeAlternates() {
        #expect(MenuModel.command(for: Shortcut(.f5)) == .refresh)
        #expect(MenuModel.command(for: .cmd("r")) == .refresh)
        #expect(MenuModel.command(for: .cmd("=")) == .textLarger)
        #expect(MenuModel.command(for: .cmd("-")) == .textSmaller)
        #expect(MenuModel.command(for: .cmd("0")) == .textReset)
        #expect(MenuModel.command(for: .cmd("[")) == .back)
        #expect(MenuModel.command(for: .cmd("l")) == .focusAddress)
        #expect(MenuModel.command(for: Shortcut(.escape)) == .stop)
        #expect(Shortcut.cmd("n").display == "Cmd+N")
    }

    @Test func shortcutsWithoutARowIncludeTheAddressKey() {
        let hidden = MenuModel.shortcutsWithoutRows(ctx())
        #expect(hidden.contains { $0.0 == .cmd("l") && $0.1 == .focusAddress })
        #expect(hidden.contains { $0.0 == Shortcut(.f5) })
        #expect(!hidden.contains { $0.0 == .cmd("n") })
    }

    @Test func shortcutOnlyCommandsAreEnabledUnlessModal() {
        var c = ctx()
        #expect(MenuModel.isEnabled(.focusAddress, c))
        #expect(MenuModel.isEnabled(.textLarger, c))
        #expect(!MenuModel.isEnabled(.back, c))
        c.modal = true
        #expect(!MenuModel.isEnabled(.focusAddress, c))
    }

    @Test func labelParsing() {
        let l = MenuLabel("Sour&ce")
        #expect(l.text == "Source")
        #expect(l.mnemonicIndex == 4)
        #expect(MenuLabel("A && B").text == "A & B")
        #expect(MenuLabel("A && B").mnemonicIndex == nil)
    }

    @Test func navigationSkipsSeparatorsAndDisabled() {
        let edit = MenuModel.menus(ctx())[1].entries
        #expect(MenuNavigation.next(from: nil, in: edit, forward: true) == 0)
        #expect(MenuNavigation.next(from: 2, in: edit, forward: true) == 4)
        #expect(MenuNavigation.next(from: 0, in: edit, forward: false) == 6)
        #expect(MenuNavigation.mnemonic("A", in: edit) == 4)
    }
}

@Suite struct DialogFocusTests {
    @Test func tabCyclesAndDefaultFollowsFocusedButton() {
        var f = DialogFocus(controls: [.field("q"), .checkbox("case"), .button("next"), .button("cancel")],
                            defaultButton: "next", cancelButton: "cancel", initial: .field("q"))
        #expect(f.effectiveDefault == "next")
        f.tab()
        f.tab()
        f.tab()
        #expect(f.focused == .button("cancel"))
        #expect(f.effectiveDefault == "cancel")
        f.tab()
        #expect(f.focused == .field("q"))
        f.tab(backward: true)
        #expect(f.focused == .button("cancel"))
    }

    @Test func arrowsMoveOnlyAmongButtons() {
        var f = DialogFocus(controls: [.field("q"), .button("ok"), .button("cancel")], defaultButton: "ok", cancelButton: "cancel")
        #expect(f.focused == .button("ok"))
        var moved = f.arrow(forward: true)
        #expect(moved)
        #expect(f.focused == .button("cancel"))
        moved = f.arrow(forward: true)
        #expect(moved)
        #expect(f.focused == .button("ok"))
        f.focus(.field("q"))
        moved = f.arrow(forward: true)
        #expect(!moved)
        #expect(f.focused == .field("q"))
    }
}

@Suite struct ArtAndPagesTests {
    @Test func everyIconIsRectangularAndInPalette() {
        for icon in Icon.allCases {
            let art = icon.art
            #expect(art.isRectangular, "\(icon)")
            #expect(art.unknownCharacters.isEmpty, "\(icon) \(art.unknownCharacters)")
        }
        for frame in Icons.logoFrames {
            #expect(frame.isRectangular && frame.unknownCharacters.isEmpty)
        }
    }

    @Test func bevelsAreAtMostTwoPixels() {
        for bevel in Bevel.allCases { #expect((1...2).contains(bevel.thickness)) }
        #expect(Bevel.raisedButton.rings[0] == BevelRing(topLeft: .white, bottomRight: .black))
        #expect(Bevel.sunkenField.rings[1] == BevelRing(topLeft: .black, bottomRight: .light))
    }

    @Test func svgMergesRunsAndSkipsTransparent() {
        let art = PixelArt(["kk.", ".rr"])
        #expect(art.svg.components(separatedBy: "<rect").count - 1 == 2)
        #expect(art.svg.contains("fill='#FF0000'"))
    }

    @Test func homePageMakesNoExternalRequests() {
        let html = Pages.home(favorites: [Favorite(title: "<b>x</b>", url: "https://x.example/?a=1&b=2")], hits: 42)
        #expect(!html.contains("src=\"http") && !html.contains("src='http") && !html.contains("url(http") && !html.contains("url(\"http"))
        #expect(html.contains("&lt;b&gt;x&lt;/b&gt;"))
        #expect(html.contains("https://x.example/?a=1&amp;b=2"))
        #expect(html.contains("<span>4</span><span>2</span>"))
        #expect(!html.lowercased().contains("<blink"))
    }

    @Test func errorPageEscapes() {
        let html = Pages.error(url: "http://x/<script>", reason: "a & b")
        #expect(html.contains("The page cannot be displayed"))
        #expect(html.contains("http://x/&lt;script&gt;"))
        #expect(!html.contains("<script>"))
    }

    @Test func scrollButtonIsARaisedSixteenPixelSquare() {
        let b = Pages.scrollButton(.arrowUp)
        #expect(b.width == 16 && b.height == 16 && b.isRectangular)
        #expect(b.color(x: 0, y: 0) == .white)
        #expect(b.color(x: 15, y: 15) == .black)
        #expect(b.color(x: 1, y: 1) == .light)
        #expect(b.color(x: 14, y: 14) == .gray)
        #expect(b.rows.joined().contains("k"))
    }

    @Test func favoriteRowsCarryAnIcon() {
        let menus = MenuModel.menus(MenuContext(state: BrowserWindowState(), favorites: [Favorite(title: "A", url: "https://a.example/")]))
        guard case let .item(row) = menus[4].entries.last else { Issue.record("no row"); return }
        #expect(row.icon == .favoriteItem)
        #expect(Command(id: "context.3") == .contextItem(3))
    }

    @Test func scrollbarScriptCarriesTheCSS() {
        #expect(Pages.scrollbarScript.contains("::-webkit-scrollbar-thumb"))
        #expect(!Pages.scrollbarCSS.contains("`"))
    }

    @Test func controlToken() {
        let t = ControlAuth.makeToken()
        #expect(t.count == 64)
        #expect(ControlAuth.command(in: "\(t) state", token: t) == "state")
        #expect(ControlAuth.command(in: "bad state", token: t) == nil)
        #expect(ControlAuth.command(in: "\(t)", token: t) == "")
        #expect(ControlAuth.command(in: "x", token: "") == nil)
    }
}
