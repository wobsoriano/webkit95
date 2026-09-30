import AppKit
import WebKit
import Webkit95Kit

/// Serves webkit95://home/ from memory.
final class HomeSchemeHandler: NSObject, WKURLSchemeHandler {
    var page: () -> String

    init(page: @escaping () -> String) {
        self.page = page
    }

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url else { return }
        let html: String
        if Pages.isHome(url) {
            html = page()
        } else {
            html = Pages.error(url: url.absoluteString, reason: "webkit95 has no page at this address.")
        }
        let data = Data(html.utf8)
        task.didReceive(URLResponse(url: url, mimeType: "text/html", expectedContentLength: data.count, textEncodingName: "utf-8"))
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}
}

/// Messages from the injected page scripts. Pages can post these too, so each kind may only
/// change harmless UI state (the status bar text).
final class ScriptBridge: NSObject, WKScriptMessageHandler {
    static let name = "webkit95"
    var route: (WKWebView, [String: Any]) -> Void = { _, _ in }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let webView = message.webView, let body = message.body as? [String: Any] else { return }
        MainActor.assumeIsolated { route(webView, body) }
    }

    /// Link hover for "Shortcut to ..." and a note when a popup without a click was blocked.
    static let pageScript = """
    (() => {
      const post = (m) => { try { window.webkit.messageHandlers.webkit95.postMessage(m); } catch (e) {} };
      let last = null;
      document.addEventListener('mouseover', (e) => {
        const a = e.target && e.target.closest ? e.target.closest('a[href]') : null;
        const href = a ? a.href : '';
        if (href !== last) { last = href; post({ type: 'hover', url: href }); }
      }, true);
      const open = window.open;
      window.open = function (...args) {
        const w = open.apply(this, args);
        if (!w) post({ type: 'popupBlocked', url: String(args[0] || '') });
        return w;
      };
    })();
    """
}

/// One shared configuration recipe for every browser window. Popups get their configuration
/// from WebKit (derived from the opener's), which already carries all of this.
@MainActor
enum WebConfig {
    static let bridge = ScriptBridge()
    static var home = HomeSchemeHandler(page: { "" })
    private static let userContent: WKUserContentController = {
        let c = WKUserContentController()
        c.addUserScript(WKUserScript(source: Pages.scrollbarScript, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        c.addUserScript(WKUserScript(source: ScriptBridge.pageScript, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        c.add(bridge, name: ScriptBridge.name)
        return c
    }()

    static func make() -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.userContentController = userContent
        config.setURLSchemeHandler(home, forURLScheme: Pages.scheme)
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        config.preferences.isElementFullscreenEnabled = true
        config.applicationNameForUserAgent = "Version/26.0 Safari/605.1.15 webkit95/0.1"
        return config
    }
}

/// Web Inspector only in debug builds. The page's context menu is handed to `onContextMenu`
/// and emptied, so webkit95 can show it as a Win95 menu instead of the macOS one.
final class BrowserWebView: WKWebView {
    var onContextMenu: (([NSMenuItem], NSEvent) -> Void)?

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        guard let onContextMenu else { return }
        let items = menu.items
        // Emptied, without the Services row AppKit would add, the macOS menu has nothing to show;
        // the cancel ends its tracking in case it opened anyway.
        menu.removeAllItems()
        menu.allowsContextMenuPlugIns = false
        DispatchQueue.main.async { menu.cancelTrackingWithoutAnimation() }
        onContextMenu(items, event)
    }

    override init(frame: CGRect, configuration: WKWebViewConfiguration) {
        super.init(frame: frame, configuration: configuration)
        #if DEBUG
        isInspectable = true
        #endif
        allowsBackForwardNavigationGestures = true
        allowsMagnification = false
    }

    required init?(coder: NSCoder) { fatalError() }
}
