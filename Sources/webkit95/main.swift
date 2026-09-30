import AppKit

let app = NSApplication.shared
app.setActivationPolicy(.regular)
MainActor.assumeIsolated {
    app.delegate = App.shared
}
app.run()
