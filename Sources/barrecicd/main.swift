import AppKit

/// A menu-bar-only agent: no Dock icon, no window, no main menu. `.accessory` is what makes the app
/// live entirely in the status bar; `Info.plist` carries `LSUIElement` for the same reason when the
/// binary is wrapped into a bundle (see `scripts/make-app.sh`).
///
/// `@MainActor` because everything it owns is: an `NSStatusItem` and an `NSMenu` are main-actor
/// isolated, and the compiler is right to refuse to let them be built from anywhere else.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let controller = StatusItemController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        controller.start()
    }
}

// Top-level code in `main.swift` is NOT main-actor isolated, so building the delegate here has to
// say where it is running. `assumeIsolated` is honest rather than convenient: this genuinely IS the
// main thread — it is the process entry point — and the assertion is checked at runtime.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    // NSApplication does not retain its delegate. Holding it in a local that lives until `run()`
    // returns is what keeps the status item alive; letting it go would silently empty the menu bar.
    app.delegate = delegate
    app.run()
    _ = delegate
}
