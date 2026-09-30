import Foundation

/// Turns a server suggested file name into one safe to create in the downloads folder.
public enum DownloadNaming {
    public static let fallback = "download"
    /// APFS allows 255 bytes; this leaves room for a " (99)" suffix.
    public static let byteLimit = 200

    /// A plain file name: no path separators, no control characters, no leading dots (so it
    /// is never hidden and never "." or ".."), trimmed, and at most `byteLimit` UTF-8 bytes with
    /// the extension kept.
    public static func safeName(_ suggested: String) -> String {
        var name = String(String.UnicodeScalarView(suggested.unicodeScalars.map { scalar in
            if CharacterSet.controlCharacters.contains(scalar) || "/\\:".unicodeScalars.contains(scalar) {
                return "_"
            }
            return scalar
        }))
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        while name.hasPrefix(".") { name.removeFirst() }
        name = name.trimmingCharacters(in: .whitespaces)
        if name.replacingOccurrences(of: "_", with: "").isEmpty { return fallback }
        return truncate(name)
    }

    /// `name` in `directory`, or "stem (2).ext", "stem (3).ext" and so on, the first that
    /// `exists` says is free. Never returns a taken name.
    public static func unique(_ name: String, in directory: URL, exists: (URL) -> Bool) -> URL {
        let first = directory.appendingPathComponent(name)
        if !exists(first) { return first }
        let (stem, ext) = split(name)
        var n = 2
        while true {
            let candidate = directory.appendingPathComponent("\(stem) (\(n))\(ext)")
            if !exists(candidate) { return candidate }
            n += 1
        }
    }

    static func split(_ name: String) -> (stem: String, ext: String) {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return (name, "") }
        let ext = String(name[dot...])
        // "archive.tar.gz" keeps ".gz"; an "extension" with spaces is part of the title.
        if ext.count > 16 || ext.contains(" ") { return (name, "") }
        return (String(name[..<dot]), ext)
    }

    private static func truncate(_ name: String) -> String {
        guard name.utf8.count > byteLimit else { return name }
        let (stem, ext) = split(name)
        let keepExt = ext.utf8.count < byteLimit / 2 ? ext : ""
        var cut = ""
        for ch in stem {
            if cut.utf8.count + String(ch).utf8.count + keepExt.utf8.count > byteLimit { break }
            cut.append(ch)
        }
        return cut + keepExt
    }
}
