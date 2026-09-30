import AppKit
import WebKit
import Webkit95Kit

/// Every running WKDownload with its File Download dialog.
@MainActor
final class Downloads: NSObject, WKDownloadDelegate {
    final class Item {
        let download: WKDownload
        weak var owner: BrowserWindowController?
        var destination: URL?
        var dialog: DownloadDialog?
        var observation: NSKeyValueObservation?
        var state = "starting"
        var cancelled = false
        let host: String

        init(download: WKDownload, owner: BrowserWindowController?) {
            self.download = download
            self.owner = owner
            host = download.originalRequest?.url?.host ?? "the Internet"
        }
    }

    private(set) var items: [Item] = []

    func adopt(_ download: WKDownload, from owner: BrowserWindowController) {
        download.delegate = self
        items.append(Item(download: download, owner: owner))
    }

    private func item(_ download: WKDownload) -> Item? { items.first { $0.download === download } }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String) async -> URL? {
        guard let item = item(download) else { return nil }
        let dir = App.shared.downloadDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let name = DownloadNaming.safeName(suggestedFilename)
        let url = DownloadNaming.unique(name, in: dir) { FileManager.default.fileExists(atPath: $0.path) }
        item.destination = url
        item.state = "active"
        if let owner = item.owner {
            let dialog = DownloadDialog(fileName: url.lastPathComponent, host: item.host) { [weak self, weak item] in
                guard let self, let item else { return }
                self.cancel(item)
            }
            item.dialog = dialog
            owner.present(dialog)
        }
        let id = ObjectIdentifier(download)
        item.observation = download.progress.observe(\.fractionCompleted) { [weak self] progress, _ in
            let done = progress.completedUnitCount, total = progress.totalUnitCount
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.items.first { ObjectIdentifier($0.download) == id }?.dialog?.update(received: done, total: total)
                }
            }
        }
        return url
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let item = item(download) else { return }
        item.state = "done"
        if let url = item.destination { markQuarantined(url, from: download.originalRequest?.url) }
        finish(item)
        item.owner?.showStatusNote("Download complete: \(item.destination?.lastPathComponent ?? "")")
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        guard let item = item(download) else { return }
        removePartial(item)
        item.state = item.cancelled ? "cancelled" : "failed"
        finish(item)
        if !item.cancelled {
            item.owner?.showMessage(kind: "download-error", title: "File Download", icon: .error,
                                    message: "The download of \(item.destination?.lastPathComponent ?? "the file") failed.\n\n\(error.localizedDescription)")
        }
    }

    func cancel(_ item: Item) {
        guard item.state == "active" || item.state == "starting" else { return }
        item.cancelled = true
        item.download.cancel { [weak self] _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.removePartial(item)
                    item.state = "cancelled"
                    self.finish(item)
                }
            }
        }
    }

    func cancelAll() {
        for item in items where item.state == "active" { cancel(item) }
    }

    func windowClosed(_ owner: BrowserWindowController) {
        for item in items where item.owner === owner { item.dialog = nil }
    }

    private func finish(_ item: Item) {
        item.observation = nil
        if let dialog = item.dialog { dialog.close() }
        item.dialog = nil
    }

    private func removePartial(_ item: Item) {
        guard let url = item.destination, FileManager.default.fileExists(atPath: url.path) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// WebKit's network process already quarantines downloads (agent com.apple.WebKit.Networking
    /// on macOS 27). This only fills in if a WebKit version does not, so Gatekeeper still checks
    /// a downloaded app.
    private func markQuarantined(_ url: URL, from origin: URL?) {
        var props: [String: Any] = [
            kLSQuarantineAgentNameKey as String: "webkit95",
            kLSQuarantineTypeKey as String: kLSQuarantineTypeWebDownload as String,
            kLSQuarantineTimeStampKey as String: Date(),
        ]
        if let origin { props[kLSQuarantineDataURLKey as String] = origin }
        var u = url
        var values = URLResourceValues()
        let existing = (try? u.resourceValues(forKeys: [.quarantinePropertiesKey]))?.quarantineProperties
        if existing != nil { return }
        values.quarantineProperties = props
        do { try u.setResourceValues(values) } catch { log("quarantine: \(error)") }
    }

    /// For the control socket.
    var summary: [[String: Any]] {
        items.map { ["name": $0.destination?.lastPathComponent ?? "", "path": $0.destination?.path ?? "", "state": $0.state] }
    }
}

/// "File Download": an original animation of a page flying from a globe to a folder, the file
/// name, the host, a progress bar and Cancel. Modeless, so browsing continues.
final class DownloadDialog: DialogView {
    private let animation = DownloadAnimation()
    private let progress = Win95Progress()
    private let detail = Win95Label("")

    init(fileName: String, host: String, cancel: @escaping () -> Void) {
        let width: CGFloat = 360, height: CGFloat = 170
        super.init(kind: "download", title: "File Download", modal: false, size: NSSize(width: width, height: height))
        animation.frame = NSRect(x: 12, y: 8, width: width - 24, height: 40)
        body.addSubview(animation)
        let saving = Win95Label("Saving:")
        saving.frame = NSRect(x: 12, y: 54, width: width - 24, height: 16)
        body.addSubview(saving)
        let name = Win95Label(TitleBarView.truncate("\(fileName) from \(host)", width: width - 24, bold: false))
        name.frame = NSRect(x: 12, y: 70, width: width - 24, height: 16)
        body.addSubview(name)
        progress.sunken = .sunkenField
        progress.frame = NSRect(x: 12, y: 92, width: width - 24, height: 16)
        body.addSubview(progress)
        detail.frame = NSRect(x: 12, y: 112, width: width - 24, height: 16)
        body.addSubview(detail)
        addButton("cancel", "Cancel", frame: NSRect(x: width - 12 - 75, y: height - 23 - 10, width: 75, height: 23)) { cancel() }
        setFocusOrder([.button("cancel")], defaultButton: "cancel", cancelButton: "cancel")
        onCancel = cancel
        animation.start()
    }

    required init?(coder: NSCoder) { fatalError() }

    private(set) var received: Int64 = 0

    func update(received: Int64, total: Int64) {
        self.received = received
        if total > 0 {
            progress.fraction = Double(received) / Double(total)
            detail.text = "\(Self.size(received)) of \(Self.size(total)) copied"
        } else {
            detail.text = "\(Self.size(received)) copied"
        }
    }

    static func size(_ bytes: Int64) -> String {
        bytes >= 1_048_576 ? String(format: "%.1f MB", Double(bytes) / 1_048_576) : "\(max(bytes / 1024, bytes > 0 ? 1 : 0)) KB"
    }

    override func removeFromSuperview() {
        animation.stop()
        super.removeFromSuperview()
    }
}

/// A page hopping along an arc from a globe to a folder, 10 frames a second.
final class DownloadAnimation: FaceView {
    private var step = 0
    private var timer: Timer?

    func start() {
        let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.step = (self.step + 1) % 12
                self.needsDisplay = true
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let globe = Icon.globe.art, folder = Icon.folder.art
        let gx: CGFloat = 16, fx = bounds.width - 16 - CGFloat(folder.width) * 2
        let baseY = bounds.height - CGFloat(globe.height) * 2
        PixelImages.draw(globe, at: NSPoint(x: gx, y: baseY), scale: 2)
        PixelImages.draw(folder, at: NSPoint(x: fx, y: baseY), scale: 2)
        guard step < 10 else { return }
        let t = CGFloat(step) / 9
        let startX = gx + 24, endX = fx - 8
        let x = startX + (endX - startX) * t
        let y = baseY + 4 - sin(t * .pi) * (baseY + 2)
        PixelImages.draw(.page, at: NSPoint(x: floor(x), y: floor(y)))
    }
}
