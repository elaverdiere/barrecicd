import Foundation
import Testing
@testable import BarreCore

// One fact, one test. Every state carries a negative control proving it is not entered when it
// should not be (S001 §7: "Only exercising the states found them" — three defects shared one
// symptom, a grey badge blaming an unreachable API that was answering 200).

private let fixedNow = Date(timeIntervalSince1970: 1_700_000_000)

// A ledger writes 8 hex characters; a CI API answers 40. `ledgerSHA8` and `apiSHA40` share the
// same leading 8 characters on purpose — that pairing is the whole motive for `sameCommit`.
private let ledgerSHA8 = "38f64b3b"
private let apiSHA40 = ledgerSHA8 + String(repeating: "c", count: 32)
private let apiSHA40Diff = "aaaaaaaa" + String(repeating: "c", count: 32)

// MARK: - Temp filesystem helpers for LedgerReader

private func makeTempDir() throws -> String {
    let dir = NSTemporaryDirectory() + "barrecicd-tests-\(UUID().uuidString)"
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    return dir
}

private func writeFile(_ text: String, at path: String) throws {
    try text.write(toFile: path, atomically: true, encoding: .utf8)
}

// MARK: - Derivation.badge — F01-AC1 the four states, F01-AC2 grey rules

@Suite("Derivation.badge — F01-AC1 four states, F01-AC2 grey rules")
struct BadgeStateTests {

    @Test func statusSuccess_withTipHasRun_isSuccess() {
        let run = RunState(project: "p", status: .success)
        #expect(Derivation.badge(for: run, tipHasRun: true) == .success)
    }

    @Test func statusFailure_withTipHasRun_isFailure() {
        let run = RunState(project: "p", status: .failure)
        #expect(Derivation.badge(for: run, tipHasRun: true) == .failure)
    }

    @Test func statusRunning_withTipHasRun_isRunning() {
        let run = RunState(project: "p", status: .running)
        #expect(Derivation.badge(for: run, tipHasRun: true) == .running)
    }

    @Test func statusUnknown_withTipHasRun_isUnknown() {
        let run = RunState(project: "p", status: .unknown)
        #expect(Derivation.badge(for: run, tipHasRun: true) == .unknown)
    }

    /// F01-AC2, the failure mode the whole product exists for: a tip commit with no run of its own
    /// must be grey, never green — however green the older run being reported was.
    @Test func tipHasNoRun_isUnknown_evenWhenStatusIsSuccess() {
        let run = RunState(project: "p", status: .success)
        #expect(Derivation.badge(for: run, tipHasRun: false) == .unknown)
    }

    /// Negative control for the above: the SAME run, with tipHasRun true, is green. Proves the
    /// grey-when-no-tip-run rule is conditioned on `tipHasRun` and not on `status` alone.
    @Test func tipHasRun_isSuccess_negativeControlForNoRunRule() {
        let run = RunState(project: "p", status: .success)
        #expect(Derivation.badge(for: run, tipHasRun: true) == .success)
    }

    @Test func unreachable_isUnknown_evenWhenStatusIsSuccess() {
        let run = RunState(project: "p", status: .success, unreachable: "token refused")
        #expect(Derivation.badge(for: run, tipHasRun: true) == .unknown)
    }

    /// Negative control: without `unreachable` set, the identical status/tipHasRun combination is
    /// NOT unknown — proves `unreachable` is what forces grey, not some other field.
    @Test func notUnreachable_isNotUnknown_negativeControlForUnreachableRule() {
        let run = RunState(project: "p", status: .success, unreachable: nil)
        #expect(Derivation.badge(for: run, tipHasRun: true) != .unknown)
    }
}

// MARK: - BadgeState.glyph — F01-AC3 distinguishable without colour

@Suite("BadgeState.glyph — F01-AC3 distinguishable without colour")
struct GlyphTests {

    @Test func allFourGlyphsAreDistinct() {
        let glyphs = Set(BadgeState.allCases.map(\.glyph))
        #expect(glyphs.count == BadgeState.allCases.count)
    }
}

// MARK: - Derivation.sameCommit

@Suite("Derivation.sameCommit — shorter-prefix comparison")
struct SameCommitTests {

    /// The motivating defect: the ledger's 8 characters against the API's 40 must still match.
    @Test func eightCharLedgerAgainstFortyCharAPI_sameCommit_true() {
        #expect(Derivation.sameCommit(ledgerSHA8, apiSHA40) == true)
    }

    @Test func identicalFullLengthSHAs_true() {
        #expect(Derivation.sameCommit(apiSHA40, apiSHA40) == true)
    }

    @Test func differentCommits_false() {
        #expect(Derivation.sameCommit(apiSHA40, apiSHA40Diff) == false)
    }

    @Test func oneEmptySHA_false() {
        #expect(Derivation.sameCommit("", apiSHA40) == false)
    }

    @Test func bothEmptySHA_false() {
        #expect(Derivation.sameCommit("", "") == false)
    }

    /// n < 7 is not an identification, regardless of whether the shared characters match.
    @Test func prefixTooShortToIdentify_false() {
        #expect(Derivation.sameCommit("abcde", "abcde12345") == false)
    }

    /// Boundary: exactly 7 characters is the minimum accepted identification length.
    @Test func exactlySevenMatchingChars_true() {
        #expect(Derivation.sameCommit("abcdefg", "abcdefg12345678") == true)
    }

    @Test func caseIsIgnored_true() {
        #expect(Derivation.sameCommit(ledgerSHA8.uppercased(), apiSHA40) == true)
    }

    @Test func surroundingWhitespaceIsTrimmed_true() {
        #expect(Derivation.sameCommit(" \(ledgerSHA8)\n", apiSHA40) == true)
    }
}

// MARK: - BadgeState.worst — F03-AC2 worst-state-wins across projects

@Suite("BadgeState.worst — F03-AC2 worst-state-wins")
struct WorstStateTests {

    /// The rule the spec calls out explicitly: unknown outranks failure, because a pipeline that
    /// is not running at all is a bigger problem than one that ran and said no.
    @Test func unknownOutranksFailure() {
        #expect(BadgeState.worst([.failure, .unknown]) == .unknown)
    }

    @Test func failureOutranksRunning() {
        #expect(BadgeState.worst([.running, .failure]) == .failure)
    }

    @Test func runningOutranksSuccess() {
        #expect(BadgeState.worst([.success, .running]) == .running)
    }

    /// Negative control: an all-success set does NOT collapse to anything worse than success.
    @Test func allSuccess_staysSuccess_negativeControl() {
        #expect(BadgeState.worst([.success, .success]) == .success)
    }

    @Test func emptyList_defaultsToUnknown() {
        #expect(BadgeState.worst([]) == .unknown)
    }
}

// MARK: - Derivation.derive — notes, badges, F04-AC3 SHA mismatch

@Suite("Derivation.derive — notes and F04-AC3 SHA mismatch")
struct DeriveTests {

    @Test func unreachable_producesSingleNoteRow_namingTheCause() {
        let run = RunState(project: "p", unreachable: "network timeout")
        let presentation = Derivation.derive(run: run, ledger: nil, now: fixedNow)

        #expect(presentation.badge == .unknown)
        #expect(presentation.rows.count == 1)
        #expect(presentation.rows[0].kind == .note)
        #expect(presentation.rows[0].label == "network timeout")
        #expect(presentation.tooltip.contains("network timeout"))
    }

    /// F01-AC2's tooltip rule: it names the commit with no run, never guesses.
    @Test func tipHasNoRun_producesNoteRow_namingTheTipCommit() {
        let run = RunState(project: "p", tipSHA: "deadbeef99", headSHA: apiSHA40, status: .success)
        let presentation = Derivation.derive(run: run, ledger: nil, now: fixedNow)

        #expect(presentation.badge == .unknown)
        #expect(presentation.rows.count == 1)
        #expect(presentation.rows[0].kind == .note)
        #expect(presentation.tooltip.contains("deadbeef"))
    }

    /// F04-AC4: with no ledger at all, the app is fully functional at F01 level — no note, no
    /// gate rows, just the badge for the run's own status.
    @Test func tipHasRun_noLedger_noNoteNoGateRows_negativeControl() {
        let run = RunState(project: "p", tipSHA: ledgerSHA8, headSHA: apiSHA40, status: .success)
        let presentation = Derivation.derive(run: run, ledger: nil, now: fixedNow)

        #expect(presentation.badge == .success)
        #expect(presentation.rows.isEmpty)
    }

    /// F04-AC3: the ledger's SHA does not match the run's head — no table, and the note names the
    /// run it is waiting for.
    @Test func ledgerSHAMismatchesRun_showsNoTable_namesWaitingRun() {
        let run = RunState(project: "p", tipSHA: apiSHA40, headSHA: apiSHA40, number: 42, status: .running)
        let ledger = Ledger(sha: "00000000staleworkfromapriorrun",
                             expected: ["build"],
                             verdicts: ["build": GateVerdict(name: "build", status: .pass, seconds: 10)])
        let presentation = Derivation.derive(run: run, ledger: ledger, now: fixedNow)

        #expect(presentation.rows.count == 1)
        #expect(presentation.rows[0].kind == .note)
        #expect(presentation.rows[0].label.contains("42"))
        #expect(presentation.rows[0].label.contains("00000000"))
    }

    /// Negative control for the above: when the ledger's SHA DOES match, the table appears —
    /// proves the note only fires on mismatch, not unconditionally whenever a ledger exists.
    @Test func ledgerSHAMatchesRun_showsGateTable_negativeControl() {
        let run = RunState(project: "p", tipSHA: apiSHA40, headSHA: apiSHA40, number: 42, status: .running)
        let ledger = Ledger(sha: ledgerSHA8,
                             expected: ["build"],
                             verdicts: ["build": GateVerdict(name: "build", status: .pass, seconds: 10)])
        let presentation = Derivation.derive(run: run, ledger: ledger, now: fixedNow)

        #expect(presentation.rows.contains { $0.kind == .note } == false)
        #expect(presentation.rows.contains { $0.kind == .gatePassed && $0.label == "build" })
    }
}

// MARK: - Derivation.row — F04-AC1 row states

@Suite("Derivation.row — F04-AC1 row states")
struct RowStateTests {

    @Test func passedGate_rendersPassedKind_withFormattedDuration() {
        let v = GateVerdict(name: "build", status: .pass, seconds: 125)
        let row = Derivation.row(v, now: fixedNow)

        #expect(row.kind == .gatePassed)
        #expect(row.trailing == "2m05s")
    }

    @Test func failedGate_rendersFailedKind_withDurationAndDetail() {
        let v = GateVerdict(name: "test", status: .fail, seconds: 42, detail: "exit 65")
        let row = Derivation.row(v, now: fixedNow)

        #expect(row.kind == .gateFailed)
        #expect(row.trailing == "0m42s")
        #expect(row.detail == "exit 65")
    }

    /// Negative control: an empty detail string surfaces as nil, never as an empty bullet.
    @Test func failedGate_emptyDetail_isNilNotEmptyString() {
        let v = GateVerdict(name: "test", status: .fail, seconds: 10, detail: "")
        let row = Derivation.row(v, now: fixedNow)

        #expect(row.detail == nil)
    }

    @Test func blockedGate_rendersBlockedKind_withBlockedTrailingAndDetail() {
        let v = GateVerdict(name: "deploy", status: .blocked, detail: "requires 'build'")
        let row = Derivation.row(v, now: fixedNow)

        #expect(row.kind == .gateBlocked)
        #expect(row.trailing == "blocked")
        #expect(row.detail == "requires 'build'")
    }

    /// The rule the whole ledger contract exists to protect: a gate named in EXPECTED with no
    /// file is MISSING/not-reached, and MUST NEVER render as passed.
    @Test func missingGate_rendersNotReachedKind_neverPassed() {
        let v = GateVerdict(name: "lint", status: .missing)
        let row = Derivation.row(v, now: fixedNow)

        #expect(row.kind == .gateNotReached)
        #expect(row.kind != .gatePassed)
        #expect(row.trailing == "—")
    }
}

// MARK: - Derivation.row — F02-AC1 the RUNNING row's live counter

@Suite("Derivation.row — F02-AC1 RUNNING elapsed counter")
struct RunningElapsedTests {

    /// The row F02 exists for: its trailing value is derived from a START EPOCH, and it must
    /// change when the injected clock advances — never a fixed duration.
    @Test func runningGate_elapsedChanges_whenClockAdvances() {
        let started = Date(timeIntervalSince1970: 1_000_000)
        let v = GateVerdict(name: "build", status: .running, startedAt: started)

        let earlier = Date(timeIntervalSince1970: 1_000_005)   // +5s
        let later = Date(timeIntervalSince1970: 1_000_065)     // +65s

        let rowEarlier = Derivation.row(v, now: earlier)
        let rowLater = Derivation.row(v, now: later)

        #expect(rowEarlier.kind == .gateRunning)
        #expect(rowLater.kind == .gateRunning)
        #expect(rowEarlier.trailing == "0m05s")
        #expect(rowLater.trailing == "1m05s")
        #expect(rowEarlier.trailing != rowLater.trailing)
    }

    /// Negative control: with no start epoch at all, elapsed falls back to zero rather than
    /// crashing or fabricating a value.
    @Test func runningGate_noStartedAt_elapsedIsZero() {
        let v = GateVerdict(name: "build", status: .running, startedAt: nil)
        let row = Derivation.row(v, now: fixedNow)

        #expect(row.trailing == "0m00s")
    }
}

// MARK: - Derivation.gateRows — ordering by execution time, not declaration

@Suite("Derivation.gateRows — ordered by execution time")
struct GateOrderingTests {

    /// The owner's defect: the table must be ordered by WHEN each gate actually ran (the
    /// verdict's modification time), not by its position in EXPECTED. This fixture declares the
    /// gate that ran FIRST in the SECOND position, so a declaration-order implementation fails.
    @Test func executedGates_orderedByDecidedAt_notDeclarationOrder() {
        let ranFirst = GateVerdict(name: "ran-first-declared-second", status: .pass, seconds: 1,
                                    decidedAt: Date(timeIntervalSince1970: 100))
        let ranSecond = GateVerdict(name: "ran-second-declared-first", status: .pass, seconds: 1,
                                     decidedAt: Date(timeIntervalSince1970: 200))
        let ledger = Ledger(sha: "x",
                             expected: ["ran-second-declared-first", "ran-first-declared-second"],
                             verdicts: [ranFirst.name: ranFirst, ranSecond.name: ranSecond])

        let rows = Derivation.gateRows(ledger, now: fixedNow)

        #expect(rows.map(\.label) == ["ran-first-declared-second", "ran-second-declared-first"])
    }

    @Test func tieOnDecidedAt_fallsBackToDeclarationOrder() {
        let sameInstant = Date(timeIntervalSince1970: 100)
        let a = GateVerdict(name: "a", status: .pass, seconds: 1, decidedAt: sameInstant)
        let b = GateVerdict(name: "b", status: .pass, seconds: 1, decidedAt: sameInstant)
        let ledger = Ledger(sha: "x", expected: ["a", "b"], verdicts: ["a": a, "b": b])

        let rows = Derivation.gateRows(ledger, now: fixedNow)

        #expect(rows.map(\.label) == ["a", "b"])
    }

    /// Not-yet-reached gates sort to the bottom, in declaration order, because for them the
    /// declared order is a plan, not a record of execution.
    @Test func notReachedGates_sortAtBottom_inDeclarationOrder() {
        let done = GateVerdict(name: "done", status: .pass, seconds: 1,
                                decidedAt: Date(timeIntervalSince1970: 100))
        let missingB = GateVerdict(name: "missing-b", status: .missing)
        let missingA = GateVerdict(name: "missing-a", status: .missing)
        let ledger = Ledger(sha: "x", expected: ["missing-b", "done", "missing-a"],
                             verdicts: [done.name: done, missingB.name: missingB, missingA.name: missingA])

        let rows = Derivation.gateRows(ledger, now: fixedNow)

        #expect(rows.map(\.label) == ["done", "missing-b", "missing-a"])
    }
}

// MARK: - Derivation.combine — F03 several projects

@Suite("Derivation.combine — F03 several projects")
struct CombineTests {

    @Test func worstStateAcrossProjects_winsTheBadge() {
        let a = RunState(project: "a", tipSHA: ledgerSHA8, headSHA: apiSHA40, status: .success)
        let b = RunState(project: "b", tipSHA: ledgerSHA8, headSHA: apiSHA40, status: .failure)
        let presentation = Derivation.combine([(a, nil), (b, nil)], now: fixedNow)

        #expect(presentation.badge == .failure)
    }

    /// Restated at the combine level: unknown (an unreachable project) outranks a plain failure
    /// elsewhere.
    @Test func unreachableProjectOutranksFailureElsewhere() {
        let a = RunState(project: "a", tipSHA: ledgerSHA8, headSHA: apiSHA40, status: .failure)
        let b = RunState(project: "b", unreachable: "token refused")
        let presentation = Derivation.combine([(a, nil), (b, nil)], now: fixedNow)

        #expect(presentation.badge == .unknown)
    }

    /// F03-AC3: one misconfigured/unreachable project never suppresses the others' rows.
    @Test func oneUnreachableProject_doesNotSuppressAnothersRows() {
        let broken = RunState(project: "broken", unreachable: "network timeout")
        let healthy = RunState(project: "healthy", tipSHA: ledgerSHA8, headSHA: apiSHA40, status: .success)
        let healthyLedger = Ledger(sha: ledgerSHA8, expected: ["build"],
                                    verdicts: ["build": GateVerdict(name: "build", status: .pass, seconds: 5)])

        let presentation = Derivation.combine([(broken, nil), (healthy, healthyLedger)], now: fixedNow)

        #expect(presentation.rows.contains { $0.kind == .note && $0.label == "network timeout" })
        #expect(presentation.rows.contains { $0.kind == .gatePassed && $0.label == "build" })
    }

    /// F03-AC2: with more than one project, the menu groups gates under a heading per project.
    @Test func severalProjects_getAHeadingRowEach() {
        let a = RunState(project: "a", tipSHA: ledgerSHA8, headSHA: apiSHA40, status: .success)
        let b = RunState(project: "b", tipSHA: ledgerSHA8, headSHA: apiSHA40, status: .success)
        let presentation = Derivation.combine([(a, nil), (b, nil)], now: fixedNow)

        #expect(presentation.rows.filter { $0.kind == .heading }.count == 2)
    }

    /// Negative control: with a SINGLE project, no heading row is added — the whole point of
    /// `showHeading` being conditioned on `results.count > 1`.
    @Test func singleProject_getsNoHeadingRow_negativeControl() {
        let a = RunState(project: "a", tipSHA: ledgerSHA8, headSHA: apiSHA40, status: .success)
        let presentation = Derivation.combine([(a, nil)], now: fixedNow)

        #expect(presentation.rows.contains { $0.kind == .heading } == false)
    }
}

// MARK: - ConfigReader.parse

@Suite("ConfigReader.parse")
struct ConfigParseTests {

    @Test func wellFormedBlock_populatesAllFields() {
        let text = """
        [my-project]
        provider = gitea
        host     = https://ci.example.com:8080/
        repo     = owner/repo
        branch   = main
        ledger   = ~/.cache/x
        logs     = ~/.cache/y
        """
        let result = ConfigReader.parse(text)

        #expect(result.count == 1)
        #expect(result[0].name == "my-project")
        #expect(result[0].provider == "gitea")
        #expect(result[0].host == "https://ci.example.com:8080")   // trailing slash stripped
        #expect(result[0].repo == "owner/repo")
        #expect(result[0].branch == "main")
        #expect(result[0].ledger == "~/.cache/x")
        #expect(result[0].logs == "~/.cache/y")
    }

    @Test func unknownKey_isIgnored_notFatal() {
        let text = """
        [my-project]
        provider = gitea
        host = https://example.com
        repo = a/b
        this-key-does-not-exist = whatever
        """
        let result = ConfigReader.parse(text)

        #expect(result.count == 1)
        #expect(result[0].repo == "a/b")
    }

    /// A project missing an essential field (host or repo) is dropped, not half-built — and it
    /// must not disturb the project declared after it.
    @Test func blockMissingRequiredField_isDropped_othersSurvive() {
        let text = """
        [bad]
        provider = gitea
        branch = main

        [good]
        host = https://example.com
        repo = a/b
        """
        let result = ConfigReader.parse(text)

        #expect(result.count == 1)
        #expect(result[0].name == "good")
    }

    @Test func commentsAndBlankLines_areIgnored() {
        let text = """
        # a leading comment
        ; a semicolon comment too

        [my-project]
        # comment inside a block
        host = https://example.com

        repo = a/b
        """
        let result = ConfigReader.parse(text)

        #expect(result.count == 1)
        #expect(result[0].host == "https://example.com")
        #expect(result[0].repo == "a/b")
    }

    @Test func missingProviderAndBranch_defaultToGiteaAndMain() {
        let text = """
        [x]
        host = h
        repo = r
        """
        let result = ConfigReader.parse(text)

        #expect(result[0].provider == "gitea")
        #expect(result[0].branch == "main")
    }

    /// Negative control: an explicitly-set provider/branch is NOT overwritten by the default.
    @Test func explicitProviderAndBranch_areNotOverwrittenByDefault() {
        let text = """
        [x]
        host = h
        repo = r
        provider = github
        branch = release
        """
        let result = ConfigReader.parse(text)

        #expect(result[0].provider == "github")
        #expect(result[0].branch == "release")
    }
}

// MARK: - LedgerReader.read

@Suite("LedgerReader.read")
struct LedgerReadTests {

    @Test func noEXPECTEDFile_returnsNil() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }

        #expect(LedgerReader.read(directory: dir, logsDirectory: nil) == nil)
    }

    /// A malformed verdict line must never be treated as a pass.
    @Test func malformedVerdictLine_isTreatedAsMissing_neverPass() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try writeFile("build\n", at: dir + "/EXPECTED")
        try writeFile("NOT-A-VALID-STATUS-WORD\n", at: dir + "/build")

        let ledger = try #require(LedgerReader.read(directory: dir, logsDirectory: nil))

        #expect(ledger.verdicts["build"]?.status == .missing)
        #expect(ledger.verdicts["build"]?.status != .pass)
    }

    @Test func gateDeclaredWithNoFile_isMissing_withReason() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try writeFile("build\ntest\n", at: dir + "/EXPECTED")
        try writeFile("PASS\t10\texit 0\n", at: dir + "/build")
        // no file written for "test"

        let ledger = try #require(LedgerReader.read(directory: dir, logsDirectory: nil))

        #expect(ledger.verdicts["test"]?.status == .missing)
        #expect(ledger.verdicts["test"]?.detail == "the step left no verdict")
    }

    /// Negative control for the two above: a well-formed PASS line IS read as a pass, with its
    /// seconds parsed — proves missing/malformed handling doesn't just always say "missing".
    @Test func wellFormedPassLine_parsesAsPass_negativeControl() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try writeFile("build\n", at: dir + "/EXPECTED")
        try writeFile("PASS\t125\texit 0\n", at: dir + "/build")

        let ledger = try #require(LedgerReader.read(directory: dir, logsDirectory: nil))

        #expect(ledger.verdicts["build"]?.status == .pass)
        #expect(ledger.verdicts["build"]?.seconds == 125)
    }

    /// The rule that produces a counter that actually counts: for RUNNING, the second field is a
    /// START EPOCH, not a duration.
    @Test func runningLine_secondFieldParsedAsStartEpoch_notSeconds() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try writeFile("build\n", at: dir + "/EXPECTED")
        try writeFile("RUNNING\t1700000000\tcompiling\n", at: dir + "/build")

        let ledger = try #require(LedgerReader.read(directory: dir, logsDirectory: nil))
        let v = try #require(ledger.verdicts["build"])

        #expect(v.status == .running)
        #expect(v.startedAt == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(v.seconds == nil)
        #expect(v.detail == "compiling")
    }

    @Test func shaFile_isReadAndTrimmed() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try writeFile("build\n", at: dir + "/EXPECTED")
        try writeFile("PASS\t1\texit 0\n", at: dir + "/build")
        try writeFile("  \(ledgerSHA8)  \n", at: dir + "/SHA")

        let ledger = try #require(LedgerReader.read(directory: dir, logsDirectory: nil))

        #expect(ledger.sha == ledgerSHA8)
    }
}

// MARK: - formatDuration — one shape everywhere: MmSSs

@Suite("formatDuration — one shape everywhere")
struct FormatDurationTests {

    @Test func zeroSeconds_formats0m00s() {
        #expect(formatDuration(0) == "0m00s")
    }

    @Test func underOneMinute_formatsWithZeroPaddedSeconds() {
        #expect(formatDuration(42) == "0m42s")
    }

    @Test func overOneMinute_formatsMinutesAndSeconds() {
        #expect(formatDuration(125) == "2m05s")
    }

    /// Negative control: a negative input never produces a negative or malformed string — it
    /// clamps to zero rather than fabricating something worse than showing nothing.
    @Test func negativeSeconds_clampsToZero() {
        #expect(formatDuration(-5) == "0m00s")
    }
}
