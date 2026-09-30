// Crops a PNG to a pixel rectangle (origin top left) and scales it up with nearest neighbour,
// so small details such as the traffic lights can be read. Also prints, per column band, the
// topmost and bottommost row of each traffic light, which makes a vertical
// misalignment a number instead of a judgement call. Inactive windows draw grey lights, so a
// light is any pixel that differs clearly from the crop's most common colour (the title bar).
// Usage: swift scripts/crop.swift in.png out.png x y w h [scale=3]
import AppKit

let a = CommandLine.arguments
guard a.count >= 7, let x = Int(a[3]), let y = Int(a[4]), let w = Int(a[5]), let h = Int(a[6]),
      let src = NSImage(contentsOfFile: a[1])?.cgImage(forProposedRect: nil, context: nil, hints: nil),
      let cropped = src.cropping(to: CGRect(x: x, y: y, width: w, height: h)) else {
    FileHandle.standardError.write(Data("usage: crop.swift in.png out.png x y w h [scale]\n".utf8))
    exit(2)
}
let scale = a.count > 7 ? Int(a[7]) ?? 3 : 3
let rep = NSBitmapImageRep(cgImage: cropped)
let ctx = CGContext(data: nil, width: w * scale, height: h * scale, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.interpolationQuality = .none
ctx.draw(cropped, in: CGRect(x: 0, y: 0, width: w * scale, height: h * scale))
let out = NSBitmapImageRep(cgImage: ctx.makeImage()!)
try! out.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: a[2]))

func rgb(_ cx: Int, _ cy: Int) -> (Double, Double, Double) {
    guard let c = rep.colorAt(x: cx, y: cy)?.usingColorSpace(.deviceRGB) else { return (0, 0, 0) }
    return (c.redComponent, c.greenComponent, c.blueComponent)
}
var counts: [String: Int] = [:]
var samples: [String: (Double, Double, Double)] = [:]
for cx in 0..<w { for cy in 0..<h {
    let c = rgb(cx, cy)
    let key = "\(Int(c.0 * 32))-\(Int(c.1 * 32))-\(Int(c.2 * 32))"
    counts[key, default: 0] += 1
    samples[key] = c
} }
let bg = samples[counts.max { $0.value < $1.value }!.key]!
func isLight(_ cx: Int, _ cy: Int) -> Bool {
    let c = rgb(cx, cy)
    return abs(c.0 - bg.0) + abs(c.1 - bg.1) + abs(c.2 - bg.2) > 0.15
}
var inBlob = false, start = 0, top = Int.max, bottom = -1
func flush(_ end: Int) {
    print("blob \(start) \(end) \(top) \(bottom) \(Double(top + bottom) / 2)")
}
for cx in 0..<w {
    var colTop = Int.max, colBottom = -1
    for cy in 0..<h {
        if isLight(cx, cy) {
            colTop = min(colTop, cy)
            colBottom = max(colBottom, cy)
        }
    }
    if colBottom >= 0 {
        if !inBlob { inBlob = true; start = cx; top = Int.max; bottom = -1 }
        top = min(top, colTop)
        bottom = max(bottom, colBottom)
    } else if inBlob {
        inBlob = false
        flush(cx)
    }
}
if inBlob { flush(w) }
