import Foundation

/// View > Fonts in IE3, five steps applied as WKWebView.pageZoom.
public enum TextSize: Int, CaseIterable, Sendable, Codable {
    case smallest, smaller, medium, larger, largest

    public var pageZoom: Double {
        switch self {
        case .smallest: 0.75
        case .smaller: 0.875
        case .medium: 1.0
        case .larger: 1.25
        case .largest: 1.5
        }
    }

    public var title: String {
        switch self {
        case .smallest: "Smallest"
        case .smaller: "Smaller"
        case .medium: "Medium"
        case .larger: "Larger"
        case .largest: "Largest"
        }
    }

    public var stepUp: TextSize { TextSize(rawValue: rawValue + 1) ?? self }
    public var stepDown: TextSize { TextSize(rawValue: rawValue - 1) ?? self }
}

/// The status bar's right panel.
public enum SecurityZone: Equatable, Sendable {
    case internet
    case localIntranet
    case myComputer

    public static func of(_ url: URL?) -> SecurityZone {
        guard let url else { return .myComputer }
        switch url.scheme?.lowercased() {
        case "http", "https":
            let host = url.host?.lowercased() ?? ""
            return host == "localhost" || host.hasPrefix("127.") || host == "::1" ? .localIntranet : .internet
        default:
            return .myComputer
        }
    }

    public var title: String {
        switch self {
        case .internet: "Internet zone"
        case .localIntranet: "Local intranet zone"
        case .myComputer: "My Computer"
        }
    }
}

public struct FindState: Equatable, Sendable {
    public var query = ""
    public var matchCase = false
    public var searchDown = true
    /// nil before the first Find Next.
    public var lastFound: Bool?

    public init() {}
}

/// Where the page's declutter stands. A new page starts idle again.
public enum DeclutterPhase: Equatable, Sendable {
    case idle
    case running(progress: Double)
    /// Something is hidden and Undo Declutter can bring it back.
    case applied

    public var isRunning: Bool {
        if case .running = self { return true }
        return false
    }
}

/// Everything one browser window shows, as a value. The window controller keeps it and redraws
/// from it; WebKit callbacks only ever write into it.
public struct BrowserWindowState: Equatable, Sendable {
    public var url: URL?
    public var title = ""
    public var isLoading = false
    /// 0...1 while loading.
    public var progress: Double = 0
    public var canGoBack = false
    public var canGoForward = false
    public var status = "Done"
    public var toolbarVisible = true
    public var addressBarVisible = true
    public var statusBarVisible = true
    public var assistantOpen = false
    public var assistantWidth: Double = 260
    public var textSize: TextSize = .medium
    public var isKey = false
    public var isZoomed = false
    /// Kept while the Find dialog is closed so reopening it shows the last query.
    public var find = FindState()
    public var findOpen = false
    public var declutter: DeclutterPhase = .idle
    /// Auto Declutter is on for this page's host.
    public var autoDeclutter = false

    public init() {}

    public var zone: SecurityZone { SecurityZone.of(url) }

    public static let appName = "webkit95"
    public static let assistantWidthRange: ClosedRange<Double> = 160...520

    /// "webkit95 - <page title>", falling back to the address while a page has no title.
    public var windowTitle: String {
        let page = title.isEmpty ? (url.map(Self.displayAddress) ?? "") : title
        return page.isEmpty ? Self.appName : "\(Self.appName) - \(page)"
    }

    public var addressText: String { url.map(Self.displayAddress) ?? "" }

    public static func displayAddress(_ url: URL) -> String {
        url.absoluteString == "about:blank" ? "" : url.absoluteString
    }

    public mutating func setAssistantWidth(_ width: Double) {
        assistantWidth = min(max(width, Self.assistantWidthRange.lowerBound), Self.assistantWidthRange.upperBound)
    }

    // Status texts in the words IE used.
    public static func openingStatus(_ url: URL) -> String { "Opening page \(url.absoluteString)..." }
    public static func shortcutStatus(_ url: String) -> String { "Shortcut to \(url)" }
    public static let doneStatus = "Done"
}
