/// The dev control socket's per launch token. Every command line is "<token> <command>";
/// without it any local process could drive the browser, including approving an agent tool call.
public enum ControlAuth {
    /// 32 random bytes as hex.
    public static func makeToken() -> String {
        var rng = SystemRandomNumberGenerator()
        let digits = Array("0123456789abcdef")
        return String((0..<32).flatMap { _ in
            let byte = UInt8.random(in: .min ... .max, using: &rng)
            return [digits[Int(byte >> 4)], digits[Int(byte & 15)]]
        })
    }

    /// The command after the token, or nil when the line does not start with the token.
    public static func command(in line: String, token: String) -> String? {
        guard !token.isEmpty else { return nil }
        let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
        guard let first = parts.first, equalInConstantTime(Array(first.utf8), Array(token.utf8)) else { return nil }
        return parts.count > 1 ? String(parts[1]) : ""
    }

    private static func equalInConstantTime(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for i in a.indices { diff |= a[i] ^ b[i] }
        return diff == 0
    }
}
