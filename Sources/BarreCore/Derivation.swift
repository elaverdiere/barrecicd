import Foundation

/// `(RunState, Ledger?) -> Presentation`, and nothing else in this project decides anything.
///
/// S001 §6 is emphatic about why: every defect this tool has already shipped lived here — a SHA
/// compared as forty characters against eight, a stale ledger paired with a live run number, a
/// running gate rendered as pending, a table ordered by declaration instead of by execution. Each
/// one is now a table test that runs in milliseconds without a menu bar, a network or a clock.
public enum Derivation {

    // MARK: One project

    public static func badge(for run: RunState, tipHasRun: Bool) -> BadgeState {
        if run.unreachable != nil { return .unknown }
        // F01-AC2: the branch has moved past every run we know about, so nothing is watching the
        // code being worked on. That is grey — not green, however green the older run was.
        if !tipHasRun { return .unknown }
        switch run.status {
        case .success: return .success
        case .failure: return .failure
        case .running: return .running
        case .unknown: return .unknown
        }
    }

    /// Do the tip of the branch and the run's head describe the same commit?
    ///
    /// Compared over the SHORTER of the two prefixes. Measured defect: the ledger writes eight
    /// characters and the API answers forty, so a full-length `==` said "no run for this commit"
    /// about a run that was covering it exactly, and the badge sat grey through a green pipeline.
    public static func sameCommit(_ a: String, _ b: String) -> Bool {
        let x = a.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let y = b.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !x.isEmpty, !y.isEmpty else { return false }
        let n = min(x.count, y.count)
        guard n >= 7 else { return false }   // fewer than 7 is not an identification
        return x.prefix(n) == y.prefix(n)
    }

    public static func derive(run: RunState, ledger: Ledger?, now: Date, showHeading: Bool = false) -> Presentation {
        let tipHasRun = sameCommit(run.tipSHA, run.headSHA)
        let state = badge(for: run, tipHasRun: tipHasRun)

        var rows: [MenuRow] = []
        if showHeading {
            rows.append(MenuRow(kind: .heading, label: run.project))
        }

        // Why there is no table, said in words. A status indicator that goes blank without saying
        // why is the silent failure it was built to end.
        if let why = run.unreachable {
            rows.append(MenuRow(kind: .note, label: why))
            return Presentation(badge: state, title: run.project,
                                tooltip: "\(run.project): \(why)", rows: rows)
        }
        if !tipHasRun {
            let short = String(run.tipSHA.prefix(8))
            rows.append(MenuRow(kind: .note, label: "no run yet for \(short) — nothing is watching this commit"))
            return Presentation(badge: state, title: run.project,
                                tooltip: "\(run.project): the branch tip \(short) has no run of its own", rows: rows)
        }

        // F04-AC3: a ledger belongs to ONE run. Pairing a live run number with a previous run's
        // verdicts shipped once and is worse than showing nothing, because it is confidently wrong.
        if let ledger, !ledger.sha.isEmpty, !sameCommit(ledger.sha, run.headSHA) {
            rows.append(MenuRow(kind: .note,
                                label: "waiting for run \(run.number.map(String.init) ?? "?") — the ledger on disk is for \(String(ledger.sha.prefix(8)))"))
        } else if let ledger {
            rows.append(contentsOf: gateRows(ledger, now: now))
        }

        let title = run.number.map { "#\($0)" } ?? run.project
        return Presentation(badge: state, title: title, tooltip: tooltipFor(run), rows: rows)
    }

    /// The gate table, ordered by WHEN EACH GATE ACTUALLY RAN.
    ///
    /// The owner, seeing green rows below the running one: "POURQUOI TU FAIS CELA ???". The table
    /// had been printed in declaration order, which is a claim about the config file, not about the
    /// run. Sorting on the verdict's modification time makes the display trust the filesystem
    /// instead of trusting a list — so a pipeline that reorders its steps cannot make this lie.
    /// Gates not yet reached have no time, and keep declaration order at the bottom, where the
    /// order is a plan rather than a record.
    static func gateRows(_ ledger: Ledger, now: Date) -> [MenuRow] {
        let declared = Dictionary(uniqueKeysWithValues: ledger.expected.enumerated().map { ($0.element, $0.offset) })
        let all = ledger.expected.compactMap { ledger.verdicts[$0] }

        let executed = all.filter { $0.status != .missing }
            .sorted { a, b in
                switch (a.decidedAt, b.decidedAt) {
                case let (x?, y?): return x == y ? (declared[a.name] ?? 0) < (declared[b.name] ?? 0) : x < y
                case (nil, _?):    return false
                case (_?, nil):    return true
                default:           return (declared[a.name] ?? 0) < (declared[b.name] ?? 0)
                }
            }
        let notReached = all.filter { $0.status == .missing }
            .sorted { (declared[$0.name] ?? 0) < (declared[$1.name] ?? 0) }

        return (executed + notReached).map { row($0, now: now) }
    }

    static func row(_ v: GateVerdict, now: Date) -> MenuRow {
        switch v.status {
        case .pass:
            return MenuRow(kind: .gatePassed, label: v.name,
                           trailing: formatDuration(v.seconds ?? 0), logPath: v.logPath)
        case .fail:
            // The message, not the number. `exit 65` is what xcodebuild returns for a dozen
            // unrelated conditions; the owner asked for something he can act on.
            return MenuRow(kind: .gateFailed, label: v.name,
                           trailing: formatDuration(v.seconds ?? 0), logPath: v.logPath,
                           detail: v.detail.isEmpty ? nil : v.detail)
        case .running:
            // THE counter. This is the row F02 exists for: it must move while the menu is open.
            let elapsed = v.startedAt.map { Int(now.timeIntervalSince($0)) } ?? 0
            return MenuRow(kind: .gateRunning, label: v.name,
                           trailing: formatDuration(elapsed), logPath: v.logPath)
        case .blocked:
            return MenuRow(kind: .gateBlocked, label: v.name, trailing: "blocked",
                           logPath: v.logPath, detail: v.detail.isEmpty ? nil : v.detail)
        case .skipped:
            return MenuRow(kind: .gateBlocked, label: v.name, trailing: "skipped",
                           logPath: v.logPath, detail: v.detail.isEmpty ? nil : v.detail)
        case .missing:
            return MenuRow(kind: .gateNotReached, label: v.name, trailing: "—")
        }
    }

    static func tooltipFor(_ run: RunState) -> String {
        let n = run.number.map { "run #\($0)" } ?? "run"
        return "\(run.project): \(n) on \(String(run.headSHA.prefix(8))) — \(run.status.rawValue)"
    }

    // MARK: Several projects (F03)

    /// One misconfigured project never suppresses the others (F03-AC3): each derives on its own and
    /// only the badge is combined.
    public static func combine(_ results: [(RunState, Ledger?)], now: Date) -> Presentation {
        let several = results.count > 1
        var rows: [MenuRow] = []
        var badges: [BadgeState] = []
        var titles: [String] = []

        for (run, ledger) in results {
            let p = derive(run: run, ledger: ledger, now: now, showHeading: several)
            badges.append(p.badge)
            titles.append(p.title)
            rows.append(contentsOf: p.rows)
        }
        let worst = BadgeState.worst(badges)
        let title = several ? "\(results.count) projects" : (titles.first ?? "")
        let tooltip = results.map { tooltipFor($0.0) }.joined(separator: "\n")
        return Presentation(badge: worst, title: title, tooltip: tooltip, rows: rows)
    }
}
