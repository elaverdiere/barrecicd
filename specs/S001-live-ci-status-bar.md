# Spec — a live CI status bar for macOS

**Status:** draft for a NEW repository. This file is the seed; it should move to that repo as its
`specs/S001-*.md` and be deleted here once it does.

**Working name:** `pulse` (placeholder — a menu-bar item that keeps beating).

---

## 1. Why this exists

A CI notification fires on an **event**, which makes it structurally silent about the failure that
produces none: the pipeline that never ran. A runner that exits and is not restarted, a
`paths-ignore` filter that swallows every push, a disabled workflow, a stuck queue — in every case
the last notification was green and still is, about a commit from three days ago.

Measured, 2026-08-05 to 08-06, on the project this comes from: a self-hosted runner exited after
three failed network polls, stayed down for hours with no supervision, and the CI API reported the
resulting jobs as `skipped`. Nothing was red. Nothing fired. Work continued against a pipeline that
was not running.

A badge always displays a *current* state, so "nothing is watching" can have a colour. That is the
half a notification cannot do.

### Why a native app rather than a SwiftBar plugin

A working plugin already exists and solves most of this. It has one boundary that cannot be moved:
**SwiftBar builds its menu from a script's stdout and does not rebuild a menu that is already on
screen.** So the dropdown is a snapshot — a gate's elapsed time does not tick while you watch it,
and clicking anything (including "Refresh") dismisses the menu.

This is a SwiftBar boundary, **not** a macOS one. A native app owns its `NSMenu` and may mutate
`NSMenuItem` titles while the menu is open; AppKit redraws them. That is why OneDrive's menu counts
while you look at it, and it is the entire reason for this project.

### Non-goals

- Not a CI dashboard, not a log viewer, not a build trigger. It reports; it does not act.
- No server, no daemon of its own, no telemetry.
- Not cross-platform. macOS menu-bar semantics are the product.

---

## 2. Scope

| | |
|---|---|
| Platform | macOS 14+, Apple Silicon and Intel, SwiftUI/AppKit, **zero third-party dependencies** |
| Distribution | a `.app`, launch-at-login; notarised if it leaves this machine |
| Providers | GitHub Actions, GitLab CI, Gitea Actions |
| Projects | **several at once** — one status item, or one per project (see F03) |
| Data | a remote CI API for run state, and an optional local *ledger* for per-gate detail |

---

## 3. The data contract

Two sources, deliberately separate. Everything works with only the first.

### 3.1 The CI API (required)

Per configured project the app needs, for the watched branch:

- the **tip commit SHA** of the branch;
- the **most recent pipeline**: its number, its status, its head SHA, a URL to open.

The status vocabulary is normalised on read to: `success` · `failure` · `running` · `unknown`.

### 3.2 The ledger (optional, local)

A directory the pipeline writes as it goes. Proven in production; the format is deliberately
trivial so any CI can produce it with `printf`.

```
<ledger>/SHA          the commit this ledger belongs to   →  "38f64b3b…"
<ledger>/EXPECTED     one gate name per line, declaring what the run owes
<ledger>/<gate>       one line, tab-separated:
                        RUNNING <start-epoch>  <note>
                        PASS    <seconds>      exit 0
                        FAIL    <seconds>      exit <n>
                        BLOCKED <seconds>      requires '<other-gate>'
<logs>/<gate>.log     the gate's captured output, created when the gate STARTS
```

Rules the app must honour, each one a defect already paid for:

- **A gate named in `EXPECTED` with no file is MISSING, and MISSING is a failure** — not a gap. A
  step that silently stopped running must not look like one that passed.
- **A ledger is only valid for the run whose SHA it carries.** Never "the freshest one". Pairing a
  live run number with a previous run's verdicts is worse than showing nothing, and it shipped once.
- **A gate is RUNNING** if it has a `RUNNING` marker, or (fallback) a log file whose birth time is
  newer than this run's freshest verdict. Never infer it from `EXPECTED` order — gates do not
  execute in the order they are declared.

---

## 4. User stories and acceptance criteria

### F01 — The state is always visible

**US01.** As a developer, I want one glance at the menu bar to tell me whether my pipeline is
healthy, so that I never work for hours against a CI that is not running.

- **AC1** — The status item shows exactly one of four states: **green** (latest commit on the
  watched branch has a run and it passed), **red** (has a run, it failed), **orange** (has a run, in
  progress), **grey** (nothing is watching).
- **AC2** — Grey is entered when the API is unreachable **or** when the tip commit of the watched
  branch has no run of its own. The tooltip states which of the two, and never guesses.
- **AC3** — The four states are distinguishable **without colour** (shape or glyph), for
  colour-blind users and for the menu bar's own monochrome rendering.
- **AC4** — On launch, before the first poll completes, the item shows a distinct "unknown" state.
  It never shows green until green has been measured.

### F02 — The menu is live while it is open

*The reason this project exists.*

- **AC1** — With the menu open and untouched, a gate's elapsed time increments **at least once per
  second**, and a gate that changes state (`RUNNING` → `PASS`) updates within one second, without
  any click.
- **AC2** — Updating an open menu never dismisses it, never moves the highlighted item, and never
  changes item order — a menu whose rows reorder under the cursor is unusable.
- **AC3** — When the menu is closed, per-second work stops. The app does not redraw what nobody is
  looking at.

### F03 — Several projects

- **AC1** — Projects are configured in a plain-text file the user can edit and version. No
  proprietary preference blob.
- **AC2** — With more than one project, the menu-bar item shows the **worst** state across them
  (grey ≻ red ≻ orange ≻ green), and the menu groups gates under a heading per project.
- **AC3** — One misconfigured or unreachable project never suppresses the others' state.

### F04 — Per-gate detail, when a ledger exists

- **AC1** — Each declared gate renders as one row: **done/passed** with its duration,
  **done/failed** with duration and exit code, **executing** with elapsed time counting up, **not
  yet reached**.
- **AC2** — A failed row opens that gate's captured log in the user's editor.
- **AC3** — When the ledger's SHA does not match the run being displayed, **no** table is shown and
  the menu says so, naming the run it is waiting for.
- **AC4** — With no ledger at all, the app is fully functional at F01 level. The ledger is an
  enhancement, never a requirement.

### F05 — Credentials are not lying around

- **AC1** — Tokens live in the **Keychain**, one entry per project. Never in the config file, never
  in the app's preferences, never in a log line.
- **AC2** — A rejected token puts the project in **grey with the cause named** ("token refused"),
  never red — an authentication fault is not a verdict on the code.

### F06 — It survives the machine

- **AC1** — Launch at login is a toggle in the menu; the app registers itself.
- **AC2** — Sleep/wake, network loss and CI-host restarts are recovered from without a relaunch.
- **AC3** — The app never blocks the main thread on the network. All polling is off-main.

---

## 5. Non-functional requirements

| # | Requirement | How it is verified |
|---|---|---|
| N1 | **Idle CPU < 1 %** with the menu closed | `sample` / Activity Monitor over 5 min |
| N2 | Menu open: redraw ≤ 16 ms per tick | signposts, `os_signpost` interval |
| N3 | Network budget: one poll per project per interval (default 20 s), **never** per menu open when the last poll is younger than the interval | request counter in a debug build |
| N4 | Memory < 50 MB resident | Activity Monitor |
| N5 | Cold launch to first painted state < 2 s | `os_signpost` |
| N6 | No data leaves the machine except CI API calls to hosts the user configured | code review + a network test |

---

## 6. Architecture

Four layers; only the last one knows about AppKit.

```
Config        reads the project list + Keychain            (pure, testable)
Providers     GitHubProvider · GitLabProvider · GiteaProvider
              → one protocol: fetch(branch) -> RunState     (pure given a transport)
Ledger        reads a ledger directory -> [GateRow]         (pure, filesystem only)
Presentation  BadgeState + [MenuRow] derivation             (PURE — the whole point)
UI            NSStatusItem + NSMenu + Timer                 (thin; no logic)
```

**The derivation is a pure function** — `(RunState, Ledger?) -> (BadgeState, [MenuRow])`. Every rule
in §3 and §4 lives there and is unit-testable without a menu bar, a network or a clock. The UI layer
may contain no `if` about state. This is not architectural taste: the defects this tool has already
produced were all in that derivation (a SHA compared as 40 chars against 8, a stale ledger paired
with a live run number, a running gate rendered as a pending one), and every one of them is a table
test.

**Time is injected.** Elapsed values come from a `Clock` the tests control. A test that must wait a
second to check a counter is a test nobody runs.

---

## 7. Test strategy

| Quadrant | What |
|---|---|
| **Q1 unit** | The derivation, as tables: each badge state, each row state, SHA mismatch, MISSING gate, BLOCKED gate, empty `EXPECTED`, ledger present but empty, malformed line. |
| **Q2 acceptance** | Each AC above, driven through the derivation with recorded provider payloads — a real GitHub/GitLab/Gitea JSON body per case, captured once and committed. |
| **Q3 system** | The three providers against a local stub HTTP server: 200, 401, 404, 500, timeout, malformed JSON. |
| **Q4 NFR** | N1–N5 measured, with the numbers recorded in the repo and re-measured per release. |

**Negative controls are mandatory.** For every state, a test that proves the state is NOT entered
when it should not be. The grey state especially: the existing implementation shipped three defects
at once — a missing `User-Agent`, an unencoded branch name, and an empty bash array under `set -u` —
and **all three produced the same symptom**, a grey badge blaming an unreachable API that was
answering 200. Only exercising the states found them.

---

## 8. Migration from the SwiftBar plugin

The plugin stays useful and is not deleted on day one. The native app is done when it passes F01,
F02 and F04 against the same ledger, side by side with the plugin, for one working day.

The ledger format in §3.2 is **unchanged** — the existing `ci-gate.sh` wrapper keeps working with no
edit. That is deliberate: the pipeline side is proven and has no reason to churn.

---

## 9. Open questions for the owner

1. **Name.** `pulse` is a placeholder.
2. **Menu-bar item per project, or one item showing the worst state?** F03-AC2 assumes one item.
   Two projects is fine either way; five would argue for one item.
3. **Notarisation.** Needed only if the app leaves this machine. It will, if the colleague wants it.
4. **Does it replace the plugin, or live beside it?** §8 assumes beside, then replace.
