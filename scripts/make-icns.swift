// Renders the pixel art app icon into an .iconset with nearest neighbor scaling (app16 for the
// 16 px slot, app32 scaled by whole numbers for the rest), for iconutil.
// Compiled together with Win95Style.swift and Icons.swift by scripts/bundle.sh.
// Usage: make-icns <out.iconset>
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func png(_ art: PixelArt, size: Int, to url: URL) {
    let scale = size / art.width
    let pad = (size - art.width * scale) / 2
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setShouldAntialias(false)
    for y in 0..<art.height {
        for x in 0..<art.width {
            guard let c = art.color(x: x, y: y) else { continue }
            ctx.setFillColor(red: CGFloat((c.rgb >> 16) & 0xFF) / 255, green: CGFloat((c.rgb >> 8) & 0xFF) / 255, blue: CGFloat(c.rgb & 0xFF) / 255, alpha: 1)
            ctx.fill(CGRect(x: pad + x * scale, y: size - pad - (y + 1) * scale, width: scale, height: scale))
        }
    }
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
}

for (name, size) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128), ("128x128@2x", 256),
                     ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    png(size == 16 ? Icon.app16.art : Icon.app32.art, size: size, to: out.appendingPathComponent("icon_\(name).png"))
}
print(out.path)
