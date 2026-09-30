import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// usage: preview <out.png> <scale> [perRow] [name ...]   ("logo" selects the logo frames)
let args = CommandLine.arguments
let outPath = args[1]
let scale = Int(args[2])!
let perRow = args.count > 3 ? Int(args[3])! : 12
let names = Set(args.dropFirst(4))

var items: [PixelArt] = Icon.allCases.filter { names.isEmpty || names.contains($0.rawValue) }.map(\.art)
if names.isEmpty || names.contains("logo") { items += Icons.logoFrames }

let cell = 36
let pad = 4
let cols = min(perRow, items.count)
let rowsCount = (items.count + cols - 1) / cols
let width = (cols * cell + pad * 2) * scale
let height = (rowsCount * cell + pad * 2) * scale

let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

func fill(_ rgb: UInt32, _ x: Int, _ y: Int, _ w: Int, _ h: Int) {
    ctx.setFillColor(red: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255,
                     blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
    ctx.fill(CGRect(x: x * scale, y: height - (y + h) * scale, width: w * scale, height: h * scale))
}

fill(UInt32(ProcessInfo.processInfo.environment["BG"] ?? "C0C0C0", radix: 16)!, 0, 0, width / scale, height / scale)
for (i, art) in items.enumerated() {
    let ox = pad + (i % cols) * cell + (cell - art.width) / 2
    let oy = pad + (i / cols) * cell + (cell - art.height) / 2
    precondition(art.isRectangular && art.unknownCharacters.isEmpty, "bad art at index \(i)")
    for y in 0..<art.height {
        for x in 0..<art.width {
            if let c = art.color(x: x, y: y) { fill(c.rgb, ox + x, oy + y, 1, 1) }
        }
    }
}

let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: outPath) as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
CGImageDestinationFinalize(dest)
