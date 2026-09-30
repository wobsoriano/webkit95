import Foundation

extension PixelArt {
    /// The art as an SVG of crisp 1 unit rects, one per horizontal run of a color.
    public var svg: String {
        var rects = ""
        for y in 0..<height {
            var x = 0
            while x < width {
                guard let color = color(x: x, y: y) else { x += 1; continue }
                var end = x + 1
                while end < width, self.color(x: end, y: y) == color { end += 1 }
                rects += "<rect x='\(x)' y='\(y)' width='\(end - x)' height='1' fill='#\(color.hex)'/>"
                x = end
            }
        }
        return "<svg xmlns='http://www.w3.org/2000/svg' width='\(width)' height='\(height)' viewBox='0 0 \(width) \(height)' shape-rendering='crispEdges'>\(rects)</svg>"
    }

    public var dataURI: String {
        "data:image/svg+xml;base64," + Data(svg.utf8).base64EncodedString()
    }
}

extension Win95Color {
    public var hex: String {
        let s = String(rgb, radix: 16, uppercase: true)
        return String(repeating: "0", count: 6 - s.count) + s
    }
}

public enum HTML {
    public static func escape(_ text: String) -> String {
        var out = ""
        for c in text {
            switch c {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&#39;"
            default: out.append(c)
            }
        }
        return out
    }
}

/// The pages webkit95 serves itself from the webkit95: scheme. No external requests: every
/// image is an inline SVG of the app's own pixel art.
public enum Pages {
    public static let scheme = "webkit95"
    public static let homeURL = URL(string: "webkit95://home/")!

    public static func isHome(_ url: URL?) -> Bool {
        url?.scheme == scheme && url?.host == "home"
    }

    private static let cone = PixelArt([
        "......kk......",
        ".....krrk.....",
        ".....krrk.....",
        "....kwwwwk....",
        "....kwwwwk....",
        "...krrrrrrk...",
        "...krrrrrrk...",
        "..kwwwwwwwwk..",
        "..kwwwwwwwwk..",
        ".krrrrrrrrrrk.",
        ".krrrrrrrrrrk.",
        "kkkkkkkkkkkkkk",
        "kggggggggggggk",
        "kkkkkkkkkkkkkk",
    ])

    private static let tile = PixelArt([
        "ttttttttttttttt.",
        "tttttttctttttttt",
        "tttttttttttttttt",
        "tttttttttttttttt",
        "ttcttttttttttttt",
        "tttttttttttttttt",
        "tttttttttttttctt",
        "tttttttttttttttt",
        "tttttttttttttttt",
        "ttttttcttttttttt",
        "tttttttttttttttt",
        "tttttttttttttttt",
        "tttttttttttcttt.",
        "tttttttttttttttt",
        "tcttttttttttttt.",
        "tttttttttttttttt",
    ].map { $0.replacingOccurrences(of: ".", with: "t") })

    public static func home(favorites: [Favorite], hits: Int) -> String {
        let links = favorites.map {
            "<li><img src='\(Icon.favoriteItem.art.dataURI)' width='16' height='16' alt=''> <a href='\(HTML.escape($0.url))'>\(HTML.escape($0.title))</a></li>"
        }.joined(separator: "\n")
        let digits = String(format: "%07d", min(max(hits, 0), 9_999_999)).map { "<span>\($0)</span>" }.joined()
        return """
        <!DOCTYPE html>
        <html><head><meta charset="utf-8"><title>Welcome to webkit95</title>
        <style>
        body { margin: 0; background: #008080 url("\(tile.dataURI)") repeat; image-rendering: pixelated;
               font-family: "Times New Roman", Times, serif; color: #000; }
        .page { width: 600px; margin: 16px auto; background: #fff; border: 2px outset #c0c0c0; padding: 0 0 12px; }
        h1 { font-size: 30px; text-align: center; color: #000080; margin: 12px 0 4px; }
        h1 img { vertical-align: middle; }
        .tag { text-align: center; font-style: italic; margin: 0 0 8px; }
        marquee { background: #000080; color: #ffff00; font: bold 14px "Courier New", monospace; padding: 3px 0; }
        .uc { margin: 12px 16px; border: 3px solid #000;
              background: repeating-linear-gradient(-45deg, #ffff00 0 12px, #000 12px 24px); padding: 8px; }
        .uc div { background: #ffff00; border: 2px solid #000; text-align: center; font: bold 18px Arial, Helvetica, sans-serif; padding: 6px; }
        .uc img { vertical-align: middle; margin: 0 8px; }
        h2 { font-size: 20px; margin: 16px 16px 4px; color: #800000; }
        ul { margin: 4px 16px; list-style: none; padding-left: 8px; }
        li { margin: 4px 0; }
        li img { vertical-align: middle; }
        a { color: #0000ff; } a:visited { color: #800080; }
        hr { border: 0; border-top: 1px solid #808080; border-bottom: 1px solid #fff; margin: 12px 16px; }
        .counter { text-align: center; font-size: 13px; }
        .counter span { display: inline-block; width: 12px; background: #000; color: #00ff00; font: bold 14px "Courier New", monospace;
                        border: 1px solid #808080; margin: 0 1px; text-align: center; }
        .foot { text-align: center; font-size: 12px; color: #808080; }
        form { text-align: center; margin: 8px 0; }
        input[name=q] { -webkit-appearance: none; appearance: none; border-radius: 0; font: 13px Arial, Helvetica, sans-serif; border: 0; padding: 3px 4px; background: #fff;
                           box-shadow: inset -1px -1px #fff, inset 1px 1px #808080, inset -2px -2px #dfdfdf, inset 2px 2px #000; outline: none; }
        input[type=submit] { -webkit-appearance: none; appearance: none; font: 13px Arial, Helvetica, sans-serif; border: 0; padding: 4px 14px; background: #c0c0c0; color: #000;
                             box-shadow: inset -1px -1px #000, inset 1px 1px #fff, inset -2px -2px #808080, inset 2px 2px #dfdfdf; border-radius: 0; }
        input[type=submit]:active { box-shadow: inset 1px 1px #000, inset -1px -1px #fff, inset 2px 2px #808080, inset -2px -2px #dfdfdf; padding: 5px 13px 3px 15px; }
        </style></head>
        <body><div class="page">
        <h1><img src="\(Icon.app32.art.dataURI)" width="32" height="32" alt=""> Welcome to webkit95!</h1>
        <p class="tag">Your window on the World Wide Web</p>
        <marquee scrollamount="4">*** Welcome to the information superhighway! Type an address above and press Enter to start surfing. ***</marquee>
        <div class="uc"><div><img src="\(cone.dataURI)" width="28" height="28" alt="">This page is UNDER CONSTRUCTION<img src="\(cone.dataURI)" width="28" height="28" alt=""></div></div>
        <h2>Cool Links</h2>
        <ul>
        \(links)
        </ul>
        <hr>
        <form action="https://duckduckgo.com/" method="get">Search the Web: <input name="q" size="24"> <input type="submit" value="Search"></form>
        <hr>
        <p class="counter">You are visitor number \(digits) since you installed webkit95.</p>
        <p class="foot">Best viewed with webkit95 at 800 x 600. This is an homage, not affiliated with Microsoft.</p>
        </div></body></html>
        """
    }

    public static func error(url: String, reason: String) -> String {
        """
        <!DOCTYPE html>
        <html><head><meta charset="utf-8"><title>Cannot find server</title>
        <style>
        body { font: 13px Arial, Helvetica, sans-serif; margin: 16px 24px; background: #fff; color: #000; }
        table { border-collapse: collapse; }
        h1 { font-size: 18px; margin: 0 0 12px; }
        .rule { border-top: 1px solid #808080; margin: 12px 0; }
        li { margin: 4px 0; }
        .small { color: #808080; font-size: 12px; }
        a { color: #0000ff; }
        </style></head>
        <body>
        <table><tr><td valign="top" width="44"><img src="\(Icon.info.art.dataURI)" width="32" height="32" alt=""></td>
        <td><h1>The page cannot be displayed</h1>
        <p>The page you asked for is not available right now. The site may be down for a while, the address may be mistyped, or your connection to the Internet may have a problem.</p>
        <div class="rule"></div>
        <p>Please try the following:</p>
        <ul>
        <li>Click the <b>Refresh</b> button, or try again later.</li>
        <li>If you typed the page address in the Address bar, make sure that it is spelled correctly.</li>
        <li>Check that your computer is connected to the Internet.</li>
        <li>Click the <b>Back</b> button to try another link.</li>
        </ul>
        <div class="rule"></div>
        <p><b>Cannot find server or DNS Error</b><br>webkit95</p>
        <p class="small">Address: \(HTML.escape(url))<br>Details: \(HTML.escape(reason))</p>
        </td></tr></table>
        </body></html>
        """
    }

    /// Injected into every frame at document start so web pages get Windows 95 scrollbars.
    public static var scrollbarScript: String {
        let css = scrollbarCSS.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "`", with: "\\`")
        return """
        (() => {
          const add = () => {
            if (document.getElementById('__webkit95_scrollbars')) return;
            const style = document.createElement('style');
            style.id = '__webkit95_scrollbars';
            style.textContent = `\(css)`;
            (document.head || document.documentElement).appendChild(style);
          };
          if (document.documentElement) add(); else document.addEventListener('DOMContentLoaded', add);
        })();
        """
    }

    /// A 16x16 raised scrollbar button with `glyph` centered, as one piece of art.
    static func scrollButton(_ glyph: Icon) -> PixelArt {
        var grid = (0..<16).map { _ in Array(repeating: Win95Color.silver.rawValue, count: 16) }
        for (inset, ring) in Bevel.raisedButton.rings.enumerated() {
            let lo = inset, hi = 15 - inset
            for i in lo...hi {
                grid[hi][i] = ring.bottomRight.rawValue
                grid[i][hi] = ring.bottomRight.rawValue
            }
            for i in lo..<hi {
                grid[lo][i] = ring.topLeft.rawValue
                grid[i][lo] = ring.topLeft.rawValue
            }
        }
        let art = glyph.art
        let ox = (16 - art.width) / 2, oy = (16 - art.height) / 2
        for y in 0..<art.height {
            for x in 0..<art.width {
                if let c = art.color(x: x, y: y) { grid[oy + y][ox + x] = c.rawValue }
            }
        }
        return PixelArt(grid.map { String($0) })
    }

    /// WebKit on macOS draws no ::-webkit-scrollbar-button, so the arrow buttons are painted
    /// into the scrollbar's own background and the track is kept clear of them with margins.
    /// They are pictures: clicking them does not scroll.
    public static var scrollbarCSS: String {
        let raised = "inset -1px -1px #000, inset 1px 1px #fff, inset -2px -2px #808080, inset 2px 2px #dfdfdf"
        let dither = PixelArt(["ws", "sw"]).dataURI
        func img(_ icon: Icon) -> String { "url(\"\(scrollButton(icon).dataURI)\")" }
        return """
        ::-webkit-scrollbar { width: 16px; height: 16px; background-color: #c0c0c0; }
        ::-webkit-scrollbar:vertical { background: \(img(.arrowUp)) top / 16px 16px no-repeat, \(img(.arrowDown)) bottom / 16px 16px no-repeat, #c0c0c0; }
        ::-webkit-scrollbar:horizontal { background: \(img(.arrowLeft)) left / 16px 16px no-repeat, \(img(.arrowRight)) right / 16px 16px no-repeat, #c0c0c0; }
        ::-webkit-scrollbar-track { background: #c0c0c0 url("\(dither)") repeat; image-rendering: pixelated; }
        ::-webkit-scrollbar-track:vertical { margin: 16px 0; }
        ::-webkit-scrollbar-track:horizontal { margin: 0 16px; }
        ::-webkit-scrollbar-thumb { background: #c0c0c0; box-shadow: \(raised); min-height: 8px; min-width: 8px; }
        ::-webkit-scrollbar-corner { background: #c0c0c0; }
        """
    }
}
