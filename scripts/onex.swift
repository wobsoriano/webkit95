// Turns a 2x Retina capture into the exact 1x image by keeping the top left pixel of every 2x2
// block (every Win95 pixel is drawn as a 2x2 block, so nothing is lost), and optionally crops.
// Usage: swift scripts/onex.swift <in.png> <out.png> [x y w h in 1x points [zoom]]
// A zoom above 1 blows each pixel up to a square, for inspecting bevels.
import AppKit

let args = CommandLine.arguments
guard args.count >= 3, let src = NSImage(contentsOfFile: args[1]),
      let cg = src.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    FileHandle.standardError.write(Data("usage: onex.swift in.png out.png [x y w h]\n".utf8))
    exit(2)
}
let factor = max(cg.width / Int(src.size.width.rounded()), 1)
let full = CGRect(x: 0, y: 0, width: cg.width / factor, height: cg.height / factor)
let crop = args.count >= 7 ? CGRect(x: Double(args[3])!, y: Double(args[4])!, width: Double(args[5])!, height: Double(args[6])!).intersection(full) : full
let zoom = args.count >= 8 ? max(Int(args[7]) ?? 1, 1) : 1
let w = Int(crop.width) * zoom, h = Int(crop.height) * zoom
let rep = NSBitmapImageRep(cgImage: cg)
let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                           isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
for y in 0..<h {
    for x in 0..<w {
        if let c = rep.colorAt(x: (Int(crop.minX) + x / zoom) * factor, y: (Int(crop.minY) + y / zoom) * factor) { out.setColor(c, atX: x, y: y) }
    }
}
try out.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[2]))
print(args[2])
