// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "webkit95",
    platforms: [.macOS(.v14)],
    targets: [
        // Pure Swift ACP client for `fx acp`. No UI, no WebKit.
        .target(name: "Webkit95Agent"),
        // Pure logic (URL input, favorites, downloads naming, chat model). No AppKit views.
        .target(name: "Webkit95Kit", dependencies: ["Webkit95Agent"]),
        // The app: Windows 95 style views, WKWebView host, window management.
        .executableTarget(name: "webkit95", dependencies: ["Webkit95Kit", "Webkit95Agent"]),
        // Resources/fake_agent.py is found through #filePath, not the bundle.
        .testTarget(name: "Webkit95AgentTests", dependencies: ["Webkit95Agent"], exclude: ["Resources"]),
        .testTarget(name: "Webkit95KitTests", dependencies: ["Webkit95Kit", "Webkit95Agent"]),
    ]
)
