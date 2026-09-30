/// The Windows 95 era palette: the 16 VGA colors plus the 3D light gray. Every pixel webkit95
/// draws itself comes from here.
public enum Win95Color: Character, CaseIterable, Sendable {
    case black = "k"
    case white = "w"
    case gray = "g"          // 3D shadow #808080
    case silver = "s"        // button face #C0C0C0
    case light = "l"         // 3D light #DFDFDF
    case navy = "n"
    case blue = "b"
    case teal = "t"
    case cyan = "c"
    case green = "G"
    case lime = "L"
    case yellow = "y"
    case olive = "o"
    case red = "r"
    case maroon = "m"
    case purple = "p"
    case magenta = "M"
    case tooltip = "i"       // #FFFFE1

    public var rgb: UInt32 {
        switch self {
        case .black: 0x000000
        case .white: 0xFFFFFF
        case .gray: 0x808080
        case .silver: 0xC0C0C0
        case .light: 0xDFDFDF
        case .navy: 0x000080
        case .blue: 0x0000FF
        case .teal: 0x008080
        case .cyan: 0x00FFFF
        case .green: 0x008000
        case .lime: 0x00FF00
        case .yellow: 0xFFFF00
        case .olive: 0x808000
        case .red: 0xFF0000
        case .maroon: 0x800000
        case .purple: 0x800080
        case .magenta: 0xFF00FF
        case .tooltip: 0xFFFFE1
        }
    }

    public static let face = Win95Color.silver
    public static let highlight = Win95Color.white
    public static let shadow = Win95Color.gray
    public static let darkShadow = Win95Color.black
    public static let activeTitle = Win95Color.navy
    public static let inactiveTitle = Win95Color.gray
    public static let selection = Win95Color.navy
    public static let desktop = Win95Color.teal
}

/// One 1 px ring of a bevel: the top and left edges in one color, bottom and right in another.
public struct BevelRing: Equatable, Sendable {
    public let topLeft: Win95Color
    public let bottomRight: Win95Color
}

/// A bevel is at most two rings, outermost first. Drawing code insets by one pixel per ring.
public enum Bevel: CaseIterable, Sendable {
    case raisedButton
    case pressedButton
    case windowFrame
    case sunkenField
    case thinRaised
    case thinSunken
    case groove
    case ridge

    public var rings: [BevelRing] {
        switch self {
        case .raisedButton: [.init(topLeft: .white, bottomRight: .black), .init(topLeft: .light, bottomRight: .gray)]
        case .pressedButton: [.init(topLeft: .black, bottomRight: .white), .init(topLeft: .gray, bottomRight: .light)]
        case .windowFrame: [.init(topLeft: .light, bottomRight: .black), .init(topLeft: .white, bottomRight: .gray)]
        case .sunkenField: [.init(topLeft: .gray, bottomRight: .white), .init(topLeft: .black, bottomRight: .light)]
        case .thinRaised: [.init(topLeft: .white, bottomRight: .gray)]
        case .thinSunken: [.init(topLeft: .gray, bottomRight: .white)]
        case .groove: [.init(topLeft: .gray, bottomRight: .white), .init(topLeft: .white, bottomRight: .gray)]
        case .ridge: [.init(topLeft: .white, bottomRight: .gray), .init(topLeft: .gray, bottomRight: .white)]
        }
    }

    public var thickness: Int { rings.count }
}

/// A small bitmap as rows of palette characters (see `Win95Color`); "." is transparent.
public struct PixelArt: Equatable, Sendable {
    public let rows: [String]

    public init(_ rows: [String]) { self.rows = rows }

    public var width: Int { rows.first?.count ?? 0 }
    public var height: Int { rows.count }

    /// nil for a transparent pixel.
    public func color(x: Int, y: Int) -> Win95Color? {
        let row = rows[y]
        let ch = row[row.index(row.startIndex, offsetBy: x)]
        return ch == "." ? nil : Win95Color(rawValue: ch)
    }

    /// Characters that are neither "." nor a palette color, for tests.
    public var unknownCharacters: Set<Character> {
        Set(rows.joined()).filter { $0 != "." && Win95Color(rawValue: $0) == nil }
    }

    public var isRectangular: Bool { rows.allSatisfy { $0.count == width } }
}
