import Foundation

/// Turns whatever the user typed into the address field into a URL to load.
public enum URLInput {
    public static let blank = URL(string: "about:blank")!

    public static func resolve(_ text: String) -> URL {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return blank }
        if text.contains(where: \.isWhitespace) { return search(text) }
        if hasScheme(text), let url = URL(string: text) { return url }
        if isLoopback(text), let url = URL(string: "http://" + text) { return url }
        if looksLikeHost(text), let url = URL(string: "https://" + text) { return url }
        return search(text)
    }

    public static func search(_ query: String) -> URL {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        let encoded = query.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        return URL(string: "https://duckduckgo.com/?q=" + encoded)!
    }

    // Local dev servers almost never speak TLS, so loopback gets http like in every other browser.
    private static func isLoopback(_ text: String) -> Bool {
        text.wholeMatch(of: /(localhost|127(\.\d{1,3}){3}|0\.0\.0\.0|\[::1\])(:\d+)?([\/?#].*)?/.ignoresCase()) != nil
    }

    // A digit right after the colon is a port ("example.com:8080"), not a scheme.
    private static func hasScheme(_ text: String) -> Bool {
        text.wholeMatch(of: /[A-Za-z][A-Za-z0-9+.\-]*:(?!\d).*/) != nil
    }

    private static func looksLikeHost(_ text: String) -> Bool {
        let host = text.prefix { !"/?#".contains($0) }
        if host.wholeMatch(of: /(\d{1,3}\.){3}\d{1,3}(:\d+)?/) != nil { return true }
        if host.wholeMatch(of: /\[[0-9A-Fa-f:]+\](:\d+)?/) != nil { return true }
        return host.contains(".") && !host.hasPrefix(".") && !host.hasSuffix(".")
    }
}
