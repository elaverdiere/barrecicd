import Foundation

// MARK: - What a CI run is, reduced to what a badge needs

/// The normalised status vocabulary (S001 §3.1). Every provider maps its own words into these four
/// on read, so nothing downstream ever sees a vendor spelling.
public enum RunStatus: String, Sendable {
    case success, failure, running, unknown
}

/// One project's answer from its CI API.
///
/// `tipSHA` and `headSHA` are separate on purpose and it is the difference that carries the
/// signal this tool was built for: when the branch has moved past the newest run, **nothing is
/// watching the code you are working on**, and that is neither green nor red.
public struct RunState: Sendable, Equatable {
    public var project: String
    public var tipSHA: String        // the branch's newest commit
    public var headSHA: String       // the commit the newest run actually covers
    public var number: Int?
    public var status: RunStatus
    public var url: String?
    /// Set when the project could not be read at all. Named, never guessed (F01-AC2).
    public var unreachable: String?

    public init(project: String, tipSHA: String = "", headSHA: String = "", number: Int? = nil,
                status: RunStatus = .unknown, url: String? = nil, unreachable: String? = nil) {
        self.project = project; self.tipSHA = tipSHA; self.headSHA = headSHA
        self.number = number; self.status = status; self.url = url; self.unreachable = unreachable
    }
}

// MARK: - What the badge shows

/// F01-AC1. Ordered worst-first: `Badge.worst` relies on the declaration order, because with
/// several projects the bar must show the state that most deserves attention (F03-AC2).
public enum BadgeState: Int, Sendable, Comparable, CaseIterable {
    case unknown = 0    // grey — nothing is watching, or we have not measured yet
    case failure = 1    // red
    case running = 2    // blue
    case success = 3    // green

    public static func < (a: BadgeState, b: BadgeState) -> Bool { a.rawValue < b.rawValue }

    /// The worst state across projects. `unknown` outranks `failure` deliberately: a pipeline that
    /// is not running at all is a bigger problem than one that ran and said no, and it is the
    /// failure mode that produces no notification (S001 §1).
    public static func worst(_ states: [BadgeState]) -> BadgeState { states.min() ?? .unknown }

    /// F01-AC3 — distinguishable WITHOUT colour, for colour-blind users and for the menu bar's own
    /// monochrome rendering. The glyph carries the state; the colour only reinforces it.
    public var glyph: String {
        switch self {
        case .success: return "●"     // filled — settled and good
        case .failure: return "✕"     // a cross reads as refusal at any size
        case .running: return "◐"     // half-filled — in flight
        case .unknown: return "○"     // hollow — nothing behind it
        }
    }
}

// MARK: - What a menu row is

public enum RowKind: Sendable, Equatable {
    case heading            // a project name, when several are configured
    case gatePassed
    case gateFailed
    case gateRunning
    case gateBlocked
    case gateMissing
    case gateNotReached
    case note               // a sentence: why there is no table, what we are waiting for
}

public struct MenuRow: Sendable, Equatable {
    public var kind: RowKind
    public var label: String
    /// Rendered right of the label: a duration, an elapsed counter, or nothing.
    public var trailing: String
    /// The gate's captured log, when there is one to open (F04-AC2).
    public var logPath: String?
    public var detail: String?

    public init(kind: RowKind, label: String, trailing: String = "", logPath: String? = nil, detail: String? = nil) {
        self.kind = kind; self.label = label; self.trailing = trailing
        self.logPath = logPath; self.detail = detail
    }
}

public struct Presentation: Sendable, Equatable {
    public var badge: BadgeState
    /// What sits beside the glyph in the bar. Short — the menu bar is not a log.
    public var title: String
    public var tooltip: String
    public var rows: [MenuRow]

    public init(badge: BadgeState, title: String, tooltip: String, rows: [MenuRow]) {
        self.badge = badge; self.title = title; self.tooltip = tooltip; self.rows = rows
    }
}

// MARK: - Time, injected

/// S001 §6: "A test that must wait a second to check a counter is a test nobody runs."
public protocol Clock: Sendable {
    var now: Date { get }
}

public struct SystemClock: Clock {
    public init() {}
    public var now: Date { Date() }
}

public struct FixedClock: Clock {
    public var now: Date
    public init(_ now: Date) { self.now = now }
}

/// ONE duration shape everywhere: `MmSSs`.
///
/// Measured motive, 2026-08-06: the shipped table printed bare seconds for decided gates ("305s")
/// beside "11m41s" for the running one, so the same quantity wore two shapes in one window and the
/// reader had to convert. The owner called it out; there is exactly one formatter now.
public func formatDuration(_ seconds: Int) -> String {
    let s = max(0, seconds)
    return String(format: "%dm%02ds", s / 60, s % 60)
}
