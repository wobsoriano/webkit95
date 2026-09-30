import AppKit
import CoreText
import Webkit95Kit

extension Win95Color {
    var ns: NSColor {
        NSColor(srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255, blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
    }
}

enum Fonts {
    static let uiName = "Ark-Pixel-12px-Prop-latin-Regular"
    static let monoName = "Ark-Pixel-12px-Mono-latin-Regular"
    /// The fonts' pixel grid is 1/12 em, so 12 pt lands every stroke on a whole pixel.
    static let size: CGFloat = 12

    static func register() {
        let dirs = [Bundle.main.resourceURL?.appendingPathComponent("Fonts"),
                    URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/Fonts")]
        for dir in dirs.compactMap({ $0 }) {
            guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { continue }
            for file in files where file.pathExtension == "ttf" {
                CTFontManagerRegisterFontsForURL(file as CFURL, .process, nil)
            }
            if NSFont(name: uiName, size: size) != nil { return }
        }
        log("fonts: Ark Pixel not found, falling back to the system font")
    }

    nonisolated(unsafe) static let ui: NSFont = NSFont(name: uiName, size: size) ?? .systemFont(ofSize: 11)
    nonisolated(unsafe) static let mono: NSFont = NSFont(name: monoName, size: size) ?? .monospacedSystemFont(ofSize: 11, weight: .regular)
    static let lineHeight: CGFloat = 16
    static let ascent: CGFloat = 13
}

func log(_ message: String) {
    FileHandle.standardError.write(Data("webkit95: \(message)\n".utf8))
}

/// Pixel drawing on a flipped view: whole point rects, 1 pt lines, no anti aliasing.
enum Draw {
    static func crisp() {
        guard let ctx = NSGraphicsContext.current else { return }
        ctx.shouldAntialias = false
        ctx.imageInterpolation = .none
        let cg = ctx.cgContext
        cg.setShouldSmoothFonts(false)
        cg.setAllowsFontSmoothing(false)
        cg.setShouldSubpixelPositionFonts(false)
        cg.setShouldSubpixelQuantizeFonts(false)
        cg.setAllowsFontSubpixelPositioning(false)
        cg.interpolationQuality = .none
    }

    static func fill(_ rect: NSRect, _ color: Win95Color) {
        color.ns.setFill()
        rect.fill()
    }

    /// Draws the rings of `bevel` inside `rect` and returns the rect inside them.
    @discardableResult
    static func bevel(_ bevel: Bevel, _ rect: NSRect) -> NSRect {
        var r = rect.integral
        for ring in bevel.rings {
            guard r.width >= 2, r.height >= 2 else { break }
            fill(NSRect(x: r.minX, y: r.minY, width: r.width - 1, height: 1), ring.topLeft)
            fill(NSRect(x: r.minX, y: r.minY, width: 1, height: r.height - 1), ring.topLeft)
            fill(NSRect(x: r.minX, y: r.maxY - 1, width: r.width, height: 1), ring.bottomRight)
            fill(NSRect(x: r.maxX - 1, y: r.minY, width: 1, height: r.height), ring.bottomRight)
            r = r.insetBy(dx: 1, dy: 1)
        }
        return r
    }

    /// The black 1 px border around the default push button, then the raised bevel inside it.
    static func defaultButton(_ rect: NSRect, pressed: Bool) {
        fill(NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: 1), .black)
        fill(NSRect(x: rect.minX, y: rect.maxY - 1, width: rect.width, height: 1), .black)
        fill(NSRect(x: rect.minX, y: rect.minY, width: 1, height: rect.height), .black)
        fill(NSRect(x: rect.maxX - 1, y: rect.minY, width: 1, height: rect.height), .black)
        let inner = rect.insetBy(dx: 1, dy: 1)
        if pressed {
            // A pressed default button is a flat gray outline, as in Windows 95.
            fill(NSRect(x: inner.minX, y: inner.minY, width: inner.width, height: 1), .gray)
            fill(NSRect(x: inner.minX, y: inner.maxY - 1, width: inner.width, height: 1), .gray)
            fill(NSRect(x: inner.minX, y: inner.minY, width: 1, height: inner.height), .gray)
            fill(NSRect(x: inner.maxX - 1, y: inner.minY, width: 1, height: inner.height), .gray)
        } else {
            bevel(.raisedButton, inner)
        }
    }

    /// The dotted focus rectangle: every other pixel black along each edge.
    static func focusRect(_ rect: NSRect) {
        let r = rect.integral
        Win95Color.black.ns.setFill()
        var x = r.minX
        while x < r.maxX {
            NSRect(x: x, y: r.minY, width: 1, height: 1).fill()
            NSRect(x: x, y: r.maxY - 1, width: 1, height: 1).fill()
            x += 2
        }
        var y = r.minY
        while y < r.maxY {
            NSRect(x: r.minX, y: y, width: 1, height: 1).fill()
            NSRect(x: r.maxX - 1, y: y, width: 1, height: 1).fill()
            y += 2
        }
    }

    /// The 50 percent checkerboard of the scrollbar track and pressed toolbar buttons.
    static func dither(_ rect: NSRect, _ a: Win95Color, _ b: Win95Color) {
        fill(rect, a)
        b.ns.setFill()
        let r = rect.integral
        var y = r.minY
        while y < r.maxY {
            var x = r.minX + ((Int(y) + Int(r.minX)) % 2 == 0 ? 1 : 0)
            while x < r.maxX {
                NSRect(x: x, y: y, width: 1, height: 1).fill()
                x += 2
            }
            y += 1
        }
    }

    static func hline(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ c: Win95Color) { fill(NSRect(x: x, y: y, width: w, height: 1), c) }
    static func vline(_ x: CGFloat, _ y: CGFloat, _ h: CGFloat, _ c: Win95Color) { fill(NSRect(x: x, y: y, width: 1, height: h), c) }

    /// An etched separator: gray line with a white line under or right of it.
    static func etched(horizontal: Bool, at p: NSPoint, length: CGFloat) {
        if horizontal {
            hline(p.x, p.y, length, .gray)
            hline(p.x, p.y + 1, length, .white)
        } else {
            vline(p.x, p.y, length, .gray)
            vline(p.x + 1, p.y, length, .white)
        }
    }

    // MARK: text

    static func attributes(_ font: NSFont = Fonts.ui, _ color: Win95Color) -> [NSAttributedString.Key: Any] {
        [.font: font, .foregroundColor: color.ns]
    }

    static func width(_ text: String, font: NSFont = Fonts.ui, bold: Bool = false) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: font]).width) + (bold ? 1 : 0)
    }

    /// Draws one line with its top at `origin.y`. Bold is the bitmap font trick of drawing the
    /// glyphs twice one pixel apart. `underline` is the index of the mnemonic character.
    static func text(_ text: String, at origin: NSPoint, color: Win95Color = .black, font: NSFont = Fonts.ui,
                     bold: Bool = false, underline: Int? = nil) {
        crisp()
        let p = NSPoint(x: round(origin.x), y: round(origin.y))
        let attrs = attributes(font, color)
        (text as NSString).draw(at: p, withAttributes: attrs)
        if bold { (text as NSString).draw(at: NSPoint(x: p.x + 1, y: p.y), withAttributes: attrs) }
        if let underline, underline < text.count {
            let start = text.index(text.startIndex, offsetBy: underline)
            let before = width(String(text[..<start]), font: font)
            let charWidth = width(String(text[start]), font: font)
            fill(NSRect(x: p.x + before, y: p.y + Fonts.ascent + 1, width: max(charWidth - 1, 1), height: 1), color)
        }
    }

    /// Disabled text: white copy one pixel down right, gray on top.
    static func embossedText(_ string: String, at origin: NSPoint, font: NSFont = Fonts.ui, underline: Int? = nil) {
        text(string, at: NSPoint(x: origin.x + 1, y: origin.y + 1), color: .white, font: font, underline: underline)
        text(string, at: origin, color: .gray, font: font, underline: underline)
    }

    /// Word wrapped text in `rect`, returns the height used.
    @discardableResult
    static func wrapped(_ string: String, in rect: NSRect, color: Win95Color = .black, font: NSFont = Fonts.ui, bold: Bool = false) -> CGFloat {
        crisp()
        let lines = wrap(string, width: rect.width, font: font)
        var y = rect.minY
        for line in lines {
            text(line, at: NSPoint(x: rect.minX, y: y), color: color, font: font, bold: bold)
            y += Fonts.lineHeight
        }
        return CGFloat(lines.count) * Fonts.lineHeight
    }

    static func wrap(_ string: String, width: CGFloat, font: NSFont = Fonts.ui) -> [String] {
        var lines: [String] = []
        for paragraph in string.components(separatedBy: "\n") {
            var line = ""
            for word in paragraph.split(separator: " ", omittingEmptySubsequences: false).map(String.init) {
                let candidate = line.isEmpty ? word : line + " " + word
                if Draw.width(candidate, font: font) <= width || line.isEmpty {
                    line = candidate
                    // A single word wider than the line is broken by characters.
                    while Draw.width(line, font: font) > width && line.count > 1 {
                        var head = ""
                        for ch in line {
                            if Draw.width(head + String(ch), font: font) > width { break }
                            head.append(ch)
                        }
                        if head.isEmpty { break }
                        lines.append(head)
                        line = String(line.dropFirst(head.count))
                    }
                } else {
                    lines.append(line)
                    line = word
                }
            }
            lines.append(line)
        }
        return lines
    }
}

/// Pixel art turned into images once, drawn with nearest neighbor sampling.
@MainActor
enum PixelImages {
    enum Variant: Hashable { case normal, gray, embossed, white }
    private struct Key: Hashable { let rows: [String]; let variant: Variant }
    private static var cache: [Key: NSImage] = [:]

    static func image(_ art: PixelArt, _ variant: Variant = .normal) -> NSImage {
        let key = Key(rows: art.rows, variant: variant)
        if let hit = cache[key] { return hit }
        let image = render(art, variant)
        cache[key] = image
        return image
    }

    static func image(_ icon: Icon, _ variant: Variant = .normal) -> NSImage { image(icon.art, variant) }

    /// Draws `art` with its top left at `origin` at 1 art pixel per point.
    static func draw(_ art: PixelArt, at origin: NSPoint, _ variant: Variant = .normal, scale: CGFloat = 1) {
        Draw.crisp()
        let img = image(art, variant)
        img.draw(in: NSRect(x: round(origin.x), y: round(origin.y), width: img.size.width * scale, height: img.size.height * scale),
                 from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.none.rawValue])
    }

    static func draw(_ icon: Icon, at origin: NSPoint, _ variant: Variant = .normal) { draw(icon.art, at: origin, variant) }

    static func draw(_ icon: Icon, centeredIn rect: NSRect, _ variant: Variant = .normal) {
        let a = icon.art
        draw(a, at: NSPoint(x: floor(rect.midX - CGFloat(a.width) / 2), y: floor(rect.midY - CGFloat(a.height) / 2)), variant)
    }

    private static func render(_ art: PixelArt, _ variant: Variant) -> NSImage {
        let pad = variant == .embossed ? 1 : 0
        let w = art.width + pad, h = art.height + pad
        var pixels = [UInt32](repeating: 0, count: max(w * h, 1))
        func put(_ x: Int, _ y: Int, _ c: Win95Color) {
            let rgb = c.rgb
            // RGBA in memory, little endian UInt32 as ABGR.
            pixels[y * w + x] = 0xFF00_0000 | ((rgb & 0xFF) << 16) | (rgb & 0xFF00) | ((rgb >> 16) & 0xFF)
        }
        for y in 0..<art.height {
            for x in 0..<art.width {
                guard let c = art.color(x: x, y: y) else { continue }
                switch variant {
                case .normal: put(x, y, c)
                case .gray: put(x, y, gray(c))
                case .white: put(x, y, .white)
                case .embossed: if isDark(c) { put(x + 1, y + 1, .white) }
                }
            }
        }
        if variant == .embossed {
            for y in 0..<art.height {
                for x in 0..<art.width {
                    if let c = art.color(x: x, y: y), isDark(c) { put(x, y, .gray) }
                }
            }
        }
        let data = pixels.withUnsafeBufferPointer { Data(buffer: $0) }
        let provider = CGDataProvider(data: data as CFData)!
        let cg = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                         space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                         provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        return NSImage(cgImage: cg, size: NSSize(width: w, height: h))
    }

    private static func luminance(_ c: Win95Color) -> Double {
        let r = Double((c.rgb >> 16) & 0xFF), g = Double((c.rgb >> 8) & 0xFF), b = Double(c.rgb & 0xFF)
        return 0.299 * r + 0.587 * g + 0.114 * b
    }

    private static func isDark(_ c: Win95Color) -> Bool { luminance(c) < 170 }

    private static func gray(_ c: Win95Color) -> Win95Color {
        let l = luminance(c)
        switch l {
        case ..<50: return .black
        case ..<150: return .gray
        case ..<205: return .silver
        case ..<235: return .light
        default: return .white
        }
    }
}
