import Foundation
import Testing
@testable import BarreCore

// F03-AC2 — several projects: one item per project (default) or one combined item, the user's
// choice. Settled by the owner on 2026-08-12 after looking at a two-project bar for a dot that
// does not exist in combined mode.
//
// One fact, one test, with the negative control beside it — the house style of DerivationTests.

private let conf = """
[naql]
provider = gitea
host     = http://192.168.0.108:8418
repo     = elaverdiere/ocr
branch   = main

[training-hub]
provider = gitea
host     = http://192.168.0.108:8418
repo     = elaverdiere/training-hub
branch   = main
"""

@Test("F03-AC2 — with no [barrecicd] section at all, the display is per-project")
func defaults_to_per_project() {
    #expect(ConfigReader.parseDisplay(conf) == .perProject)
}

@Test("F03-AC2 — display = combined is honoured")
func combined_is_honoured() {
    #expect(ConfigReader.parseDisplay("[barrecicd]\ndisplay = combined\n" + conf) == .combined)
}

@Test("F03-AC2 — display = per-project is honoured, and is not merely the default answering")
func per_project_is_honoured() {
    // The negative control for the test above: if parsing ignored the section entirely, BOTH
    // tests would still pass on the default. This one only passes if `combined` can be overridden
    // back, which a no-op parser cannot do.
    #expect(ConfigReader.parseDisplay("[barrecicd]\ndisplay = combined\n") == .combined)
    #expect(ConfigReader.parseDisplay("[barrecicd]\ndisplay = per-project\n") == .perProject)
}

@Test("F03-AC2b — an unknown display value falls back to per-project rather than failing")
func unknown_value_falls_back() {
    #expect(ConfigReader.parseDisplay("[barrecicd]\ndisplay = bananas\n") == .perProject)
}

@Test("F03-AC2 — the reserved section is not mistaken for a project")
func reserved_section_is_not_a_project() {
    // It carries neither `repo` nor `host`, so today's parser already drops it — this pins that
    // property so a future relaxation of `flush()` cannot silently grow a phantom project.
    let projects = ConfigReader.parse("[barrecicd]\ndisplay = combined\n" + conf)
    #expect(projects.map(\.name) == ["naql", "training-hub"])
}

@Test("F03-AC2c — per-project items keep the order the config declares")
func order_follows_the_config() {
    #expect(ConfigReader.parse(conf).map(\.name) == ["naql", "training-hub"])
    #expect(ConfigReader.parse("[training-hub]\nhost = h\nrepo = r\n\n[naql]\nhost = h\nrepo = r\n")
        .map(\.name) == ["training-hub", "naql"])
}

@Test("F03-AC2 — a per-project item is labelled with its project, or two dots cannot be told apart")
func per_project_presentation_carries_the_name() {
    let sha = String(repeating: "a", count: 40)
    let run = RunState(project: "training-hub", tipSHA: sha, headSHA: sha, number: 42,
                       status: .success)

    let p = Derivation.derivePerProject(run: run, ledger: nil, now: Date())

    #expect(p.title.contains("training-hub"))
    // The badge itself must still be the project's own state, not an aggregate of one.
    #expect(p.badge == .success)
}
