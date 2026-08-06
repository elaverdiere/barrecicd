import AppKit
import BarreCore
import ServiceManagement

/// The thin AppKit shell. It owns the `NSStatusItem` and the `NSMenu`, and contains no decision —
/// every state, label and colour comes from `Derivation`. S001 §6: "The UI layer may contain no
/// `if` about state."
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {

    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private let clock: Clock = SystemClock()

    private var projects: [ProjectConfig] = []
    private var configError: String?
    private var latest: [(RunState, Ledger?)] = []

    /// The rows currently on screen, and the menu items rendering them, index for index. Keeping
    /// this pairing is what allows an update in place instead of a rebuild.
    private var shownRows: [MenuRow] = []
    private var rowItems: [NSMenuItem] = []

    private var pollTimer: Timer?
    private var tickTimer: Timer?
    private var pollInterval: TimeInterval = 20

    // MARK: Lifecycle

    func start() {
        menu.delegate = self
        item.menu = menu
        item.button?.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)

        // F01-AC4 — a distinct "unknown" until green has been MEASURED. An indicator that starts
        // green is asserting something it has not checked, on the exact axis it exists to report.
        render(Presentation(badge: .unknown, title: "…", tooltip: "starting up", rows: []))

        loadConfig()
        poll()
        // The network poll runs in .common modes too: with the menu open the run loop is in event
        // tracking mode, and a default-mode timer would silently stop polling for as long as the
        // user looks at it — the menu would freeze precisely while being watched.
        let t = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        RunLoop.main.add(t, forMode: .common)
        pollTimer = t
    }

    private func loadConfig() {
        do {
            projects = try ConfigReader.load()
            configError = nil
        } catch {
            projects = []
            configError = String(describing: error)
            writeSampleConfigIfAbsent()
        }
    }

    /// On a first launch the app explains itself rather than showing an empty menu — a tool whose
    /// failure mode is a blank screen is the silent failure it was written to end.
    private func writeSampleConfigIfAbsent() {
        let path = ConfigReader.defaultPath
        guard !FileManager.default.fileExists(atPath: path) else { return }
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                 withIntermediateDirectories: true)
        try? ConfigReader.sample.write(toFile: path, atomically: true, encoding: .utf8)
    }

    // MARK: Polling — off the main thread, always (F06-AC3)

    private func poll() {
        guard !projects.isEmpty else {
            render(Presentation(badge: .unknown, title: "",
                                tooltip: configError ?? "no project configured",
                                rows: [MenuRow(kind: .note, label: configError ?? "no project configured"),
                                       MenuRow(kind: .note, label: "edit \(ConfigReader.defaultPath)")]))
            return
        }
        let snapshot = projects
        Task.detached { [weak self] in
            guard let self else { return }
            let transport = URLSessionTransport()
            var results: [(RunState, Ledger?)] = []
            // Sequential rather than concurrent: N3 budgets one request per project per interval,
            // and a handful of projects does not justify the ordering non-determinism.
            for p in snapshot {
                let run = await Providers.make(p.provider)
                    .fetch(p, token: Keychain.token(forProject: p.name), transport: transport)
                let ledger = p.ledger.flatMap { LedgerReader.read(directory: $0, logsDirectory: p.logs) }
                results.append((run, ledger))
            }
            // Handed across the actor boundary as an immutable value. Passing the mutable `results`
            // itself would let this task keep writing to something the main actor is reading.
            let collected = results
            await MainActor.run { self.apply(collected) }
        }
    }

    private func apply(_ results: [(RunState, Ledger?)]) {
        latest = results
        render(Derivation.combine(results, now: clock.now))
    }

    // MARK: The menu is live while it is open (F02) — the reason this project exists

    func menuWillOpen(_ menu: NSMenu) {
        // THE line that makes this app different from the shell plugin it replaces.
        //
        // While a menu is open AppKit runs the loop in `NSEventTrackingRunLoopMode`, and a timer
        // scheduled the ordinary way only fires in `.default`. Such a timer stops the instant the
        // menu appears and resumes when it closes — which looks exactly like "the menu is frozen",
        // and would reproduce, in a native app, the very SwiftBar boundary this project exists to
        // cross. `.common` includes event tracking.
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        tickTimer = t
        tick()
    }

    /// F02-AC3 — when nobody is looking, the per-second work stops. N1 is an idle CPU under 1 %.
    func menuDidClose(_ menu: NSMenu) {
        tickTimer?.invalidate()
        tickTimer = nil
    }

    private func tick() {
        guard !latest.isEmpty else { return }
        render(Derivation.combine(latest, now: clock.now))
    }

    // MARK: Rendering

    private func render(_ p: Presentation) {
        // The bar itself. The glyph carries the state without colour (F01-AC3); the colour only
        // reinforces it.
        let title = p.title.isEmpty ? p.badge.glyph : "\(p.badge.glyph) \(p.title)"
        item.button?.attributedTitle = NSAttributedString(
            string: title,
            attributes: [.foregroundColor: colour(p.badge),
                         .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: p.badge == .running ? .semibold : .regular)])
        item.button?.toolTip = p.tooltip

        if structureChanged(p.rows) {
            rebuild(p.rows)
        } else {
            // F02-AC2 — updating an open menu must never dismiss it, move the highlight or reorder
            // a row. Mutating the existing items' titles does none of those; rebuilding does all
            // three, which is why the structure check above earns its keep.
            for (i, row) in p.rows.enumerated() where i < rowItems.count {
                rowItems[i].attributedTitle = attributed(row)
            }
            shownRows = p.rows
        }
    }

    /// Only the SHAPE counts — a changed duration must never trigger a rebuild, or the menu would
    /// rebuild every second and F02-AC2 would be violated once per tick.
    private func structureChanged(_ rows: [MenuRow]) -> Bool {
        guard rows.count == shownRows.count, rows.count == rowItems.count else { return true }
        for (a, b) in zip(rows, shownRows) where a.kind != b.kind || a.label != b.label { return true }
        return false
    }

    private func rebuild(_ rows: [MenuRow]) {
        menu.removeAllItems()
        rowItems = []
        for row in rows {
            let mi = NSMenuItem(title: row.label, action: nil, keyEquivalent: "")
            mi.attributedTitle = attributed(row)
            if row.kind == .heading { mi.isEnabled = false }
            if let log = row.logPath, row.kind == .gateFailed || row.kind == .gateBlocked {
                mi.representedObject = log          // F04-AC2 — a failed row opens its log
                mi.target = self
                mi.action = #selector(openLog(_:))
            }
            menu.addItem(mi)
            rowItems.append(mi)
        }
        menu.addItem(.separator())

        let open = NSMenuItem(title: "Open the run in the browser", action: #selector(openRun), keyEquivalent: "o")
        open.target = self
        menu.addItem(open)

        let refresh = NSMenuItem(title: "Refresh now", action: #selector(refreshNow), keyEquivalent: "r")
        refresh.target = self
        menu.addItem(refresh)

        let edit = NSMenuItem(title: "Edit the project list…", action: #selector(editConfig), keyEquivalent: ",")
        edit.target = self
        menu.addItem(edit)

        let login = NSMenuItem(title: "Open at login", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)

        shownRows = rows
    }

    private func attributed(_ row: MenuRow) -> NSAttributedString {
        let label = row.detail.map { "\(row.label) — \($0)" } ?? row.label
        let text = row.trailing.isEmpty ? label : "\(label)  \(row.trailing)"
        var attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: row.kind == .gateRunning ? .bold : .regular)
        ]
        switch row.kind {
        case .heading:       attrs[.foregroundColor] = NSColor.secondaryLabelColor
                             attrs[.font] = NSFont.systemFont(ofSize: 11, weight: .semibold)
        case .gatePassed:    attrs[.foregroundColor] = NSColor.systemGreen
        case .gateFailed:    attrs[.foregroundColor] = NSColor.systemRed
        case .gateRunning:   attrs[.foregroundColor] = NSColor.systemBlue
        case .gateBlocked:   attrs[.foregroundColor] = NSColor.systemOrange
        case .gateMissing,
             .gateNotReached: attrs[.foregroundColor] = NSColor.tertiaryLabelColor
        case .note:          attrs[.foregroundColor] = NSColor.labelColor
        }
        return NSAttributedString(string: text, attributes: attrs)
    }

    private func colour(_ s: BadgeState) -> NSColor {
        switch s {
        case .success: return .systemGreen
        case .failure: return .systemRed
        case .running: return .systemBlue
        case .unknown: return .secondaryLabelColor
        }
    }

    // MARK: Actions

    @objc private func openLog(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    @objc private func openRun() {
        guard let s = latest.first(where: { $0.0.url != nil })?.0.url, let u = URL(string: s) else { return }
        NSWorkspace.shared.open(u)
    }

    @objc private func refreshNow() { loadConfig(); poll() }

    @objc private func editConfig() {
        writeSampleConfigIfAbsent()
        NSWorkspace.shared.open(URL(fileURLWithPath: ConfigReader.defaultPath))
    }

    @objc private func toggleLogin() {
        // F06-AC1. Only meaningful for a bundled .app; a bare binary has nothing to register.
        if SMAppService.mainApp.status == .enabled {
            try? SMAppService.mainApp.unregister()
        } else {
            try? SMAppService.mainApp.register()
        }
    }
}
