import Foundation

/// Where webkit95 keeps its files: ~/Library/Application Support/webkit95 unless
/// WEBKIT95_SUPPORT_DIR points elsewhere (scripts use a temp dir so a test run never touches the
/// real favorites or history).
public enum SupportDirectory {
    public static func resolve(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let dir = environment["WEBKIT95_SUPPORT_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: dir, isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("webkit95", isDirectory: true)
    }
}

/// A Codable value persisted as one JSON file, written atomically.
public struct JSONFile<Value: Codable & Sendable>: Sendable {
    public let url: URL

    public init(_ url: URL) { self.url = url }

    /// nil when the file is missing or unreadable, so the caller falls back to its defaults.
    public func load() -> Value? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Value.self, from: data)
    }

    public func save(_ value: Value) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(value).write(to: url, options: .atomic)
    }
}

/// The addresses the user typed, most recent first, for the address field's drop down.
public struct AddressHistory: Equatable, Sendable, Codable {
    public static let limit = 25
    public private(set) var entries: [String]

    public init(entries: [String] = []) {
        self.entries = []
        for entry in entries.reversed() { record(entry) }
    }

    /// Moves `address` to the top. Blank text and duplicates never add a row.
    public mutating func record(_ address: String) {
        let address = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty else { return }
        entries.removeAll { $0 == address }
        entries.insert(address, at: 0)
        if entries.count > Self.limit { entries.removeLast(entries.count - Self.limit) }
    }

    public init(from decoder: Decoder) throws {
        self.init(entries: try decoder.singleValueContainer().decode([String].self))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(entries)
    }
}

public struct Favorite: Equatable, Sendable, Codable, Identifiable {
    public var id: String { url }
    public let title: String
    public let url: String

    public init(title: String, url: String) {
        self.title = title
        self.url = url
    }
}

/// Favorites in menu order. The URL is the identity, so adding a page twice renames it.
public struct Favorites: Equatable, Sendable, Codable {
    public static let defaults = [
        Favorite(title: "Wikipedia", url: "https://www.wikipedia.org/"),
        Favorite(title: "Hacker News", url: "https://news.ycombinator.com/"),
        Favorite(title: "DuckDuckGo", url: "https://duckduckgo.com/"),
        Favorite(title: "Apple", url: "https://www.apple.com/"),
        Favorite(title: "GitHub", url: "https://github.com/"),
    ]
    public static let titleLimit = 120

    public private(set) var items: [Favorite]

    public init(items: [Favorite] = Favorites.defaults) {
        self.items = []
        for item in items { add(title: item.title, url: item.url) }
    }

    public mutating func add(title: String, url: String) {
        let url = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { return }
        var title = title.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .newlines).joined(separator: " ")
        if title.isEmpty { title = url }
        title = String(title.prefix(Self.titleLimit))
        let favorite = Favorite(title: title, url: url)
        if let i = items.firstIndex(where: { $0.url == url }) {
            items[i] = favorite
        } else {
            items.append(favorite)
        }
    }

    public mutating func remove(url: String) {
        items.removeAll { $0.url == url }
    }

    public init(from decoder: Decoder) throws {
        self.init(items: try decoder.singleValueContainer().decode([Favorite].self))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(items)
    }
}
