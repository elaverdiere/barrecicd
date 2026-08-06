import AppKit
import BarreCore
import Foundation

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

// `--probe`: do one full cycle, print exactly what the menu would show, and exit.
//
// A menu-bar app with no way to ask it what it sees from a terminal cannot be supported, and cannot
// be verified before it is handed to anyone: the status item is not readable by any script, so
// "does it authenticate against the real host" would otherwise be answered by looking at a dot.
// This prints the derived state — never a credential.
if CommandLine.arguments.contains("--probe") {
    let projects = (try? ConfigReader.load()) ?? []
    if projects.isEmpty {
        print("no project configured — expected \(ConfigReader.defaultPath)")
        exit(1)
    }
    let done = DispatchSemaphore(value: 0)
    Task {
        let transport = URLSessionTransport()
        var results: [(RunState, Ledger?)] = []
        for p in projects {
            let credential = CredentialStore.resolve(project: p)
            let run = await Providers.make(p.provider).fetch(p, credential: credential, transport: transport)
            let ledger = p.ledger.flatMap { LedgerReader.read(directory: $0, logsDirectory: p.logs) }
            print("[\(p.name)] credential=\(credential == nil ? "none" : "found") "
                  + "tip=\(run.tipSHA.isEmpty ? "-" : String(run.tipSHA.prefix(8))) "
                  + "run=\(run.number.map(String.init) ?? "-") status=\(run.status.rawValue)")
            results.append((run, ledger))
        }
        let p = Derivation.combine(results, now: Date())
        print("\nbadge: \(p.badge.glyph)  \(p.title)")
        print("tip:   \(p.tooltip.replacingOccurrences(of: "\n", with: "\n       "))")
        for row in p.rows {
            let kind = "\(row.kind)".padding(toLength: 15, withPad: " ", startingAt: 0)
            let label = row.label.count < 26
                ? row.label.padding(toLength: 26, withPad: " ", startingAt: 0) : row.label
            print("  \(kind)\(label) \(row.trailing)")
        }
        done.signal()
    }
    done.wait()
    exit(0)
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
