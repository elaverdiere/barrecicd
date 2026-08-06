import Foundation

/// One gate as it exists on disk, before any presentation decision is taken.
public struct GateVerdict: Sendable, Equatable {
    public enum Status: String, Sendable { case pass = "PASS", fail = "FAIL", blocked = "BLOCKED",
                                           skipped = "SKIPPED", running = "RUNNING", missing = "MISSING" }
    public var name: String
    public var status: Status
    /// Elapsed seconds for a decided gate; for `.running` this is derived from the start epoch.
    public var seconds: Int?
    /// When the gate started, for `.running` rows whose counter must tick.
    public var startedAt: Date?
    public var detail: String
    /// The verdict file's modification time — the ONLY honest account of execution order.
    public var decidedAt: Date?
    public var logPath: String?

    public init(name: String, status: Status, seconds: Int? = nil, startedAt: Date? = nil,
                detail: String = "", decidedAt: Date? = nil, logPath: String? = nil) {
        self.name = name; self.status = status; self.seconds = seconds; self.startedAt = startedAt
        self.detail = detail; self.decidedAt = decidedAt; self.logPath = logPath
    }
}

public struct Ledger: Sendable, Equatable {
    /// The commit this ledger belongs to. A ledger is valid for that run and no other (S001 §3.2).
    public var sha: String
    /// What the run owes, in declaration order. Used for "not yet reached" — never for display
    /// order, because gates do not execute in the order they are declared.
    public var expected: [String]
    public var verdicts: [String: GateVerdict]

    public init(sha: String, expected: [String], verdicts: [String: GateVerdict]) {
        self.sha = sha; self.expected = expected; self.verdicts = verdicts
    }
}

/// Reads a ledger directory. Filesystem only — no network, no clock, no AppKit.
public enum LedgerReader {

    public static func read(directory: String, logsDirectory: String?) -> Ledger? {
        let fm = FileManager.default
        let dir = (directory as NSString).expandingTildeInPath
        guard let expectedRaw = try? String(contentsOfFile: dir + "/EXPECTED", encoding: .utf8) else {
            return nil   // no EXPECTED means no ledger; the app stays fully functional (F04-AC4)
        }
        let expected = expectedRaw.split(separator: "\n").map(String.init)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }

        let sha = ((try? String(contentsOfFile: dir + "/SHA", encoding: .utf8)) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        var verdicts: [String: GateVerdict] = [:]
        for gate in expected {
            let path = dir + "/" + gate
            let logPath = logsDirectory.map { ($0 as NSString).expandingTildeInPath + "/" + gate + ".log" }
            let readableLog = logPath.flatMap { fm.fileExists(atPath: $0) ? $0 : nil }

            guard let raw = try? String(contentsOfFile: path, encoding: .utf8) else {
                // A gate named in EXPECTED with no file is MISSING, and MISSING is a failure, not a
                // gap (S001 §3.2). This exact shape let a fifteen-day coverage outage look healthy.
                verdicts[gate] = GateVerdict(name: gate, status: .missing,
                                             detail: "the step left no verdict", logPath: readableLog)
                continue
            }
            let mtime = (try? fm.attributesOfItem(atPath: path)[.modificationDate] as? Date) ?? nil

            let fields = raw.trimmingCharacters(in: .newlines).components(separatedBy: "\t")
            let statusWord = fields.first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            let value = fields.count > 1 ? Int(fields[1].trimmingCharacters(in: .whitespaces)) : nil
            let detail = fields.count > 2 ? fields[2].trimmingCharacters(in: .whitespaces) : ""

            guard let status = GateVerdict.Status(rawValue: statusWord) else {
                // A malformed line is NOT a pass. Treated as missing so it counts against the run.
                verdicts[gate] = GateVerdict(name: gate, status: .missing,
                                             detail: "unreadable verdict line", decidedAt: mtime,
                                             logPath: readableLog)
                continue
            }
            if status == .running {
                // For a RUNNING marker the second field is the START EPOCH, not a duration — the
                // whole reason the row can count up. Confusing the two prints an elapsed time that
                // never moves, which is worse than no counter because it looks like it works.
                verdicts[gate] = GateVerdict(name: gate, status: .running,
                                             startedAt: value.map { Date(timeIntervalSince1970: TimeInterval($0)) },
                                             detail: detail, decidedAt: mtime, logPath: readableLog)
            } else {
                verdicts[gate] = GateVerdict(name: gate, status: status, seconds: value,
                                             detail: detail, decidedAt: mtime, logPath: readableLog)
            }
        }
        return Ledger(sha: sha, expected: expected, verdicts: verdicts)
    }
}
