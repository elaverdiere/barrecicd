# barrecicd

A macOS menu-bar item that shows CI state — and keeps beating while you look at it.

Watches **Gitea Actions, GitHub Actions and GitLab CI**. No dependencies, no daemon, no telemetry.

The specification is the authority: [`specs/S001-live-ci-status-bar.md`](specs/S001-live-ci-status-bar.md).

---

## Install

```bash
git clone <this repo> && cd barrecicd
./scripts/make-app.sh          # builds build/barrecicd.app
open build/barrecicd.app
```

Building it yourself is the intended path, and not only out of laziness: a binary you compiled has
never crossed a quarantine boundary, so Gatekeeper never gets involved. A downloaded `.dmg` would
have to be signed with a Developer ID certificate and notarised by Apple, or it is refused on
arrival — `scripts/make-dmg.sh` explains that in its header and refuses to build a broken one.

On first launch the app writes a commented `~/.config/barrecicd/projects.conf` and opens the menu
saying so. One block per project:

```ini
[my-project]
provider = gitea            # gitea · github · gitlab
host     = https://gitea.example.com
repo     = owner/repo       # or the numeric project id, for GitLab
branch   = main
ledger   = ~/.cache/my-ci/live      # optional — gives the per-gate table
logs     = ~/.cache/my-ci/logs      # optional — lets a failed row open its log
```

Tokens are **not** in that file — it is meant to be committed. They live in the Keychain, one entry
per project:

```bash
security add-generic-password -s barrecicd -a my-project -w '<token>'
```

## What the four states mean

| | | |
|---|---|---|
| `●` green | the branch tip has a run and it passed | |
| `✕` red | it has a run and it failed | |
| `◐` blue | a run is in flight | |
| `○` grey | **nothing is watching** | the CI host is unreachable, the token was refused, or the branch tip has no run of its own |

Grey is the state this tool was written for, and the reason it says *which* of those three it is
rather than guessing. Each state has its own glyph, so the badge is readable without colour.

## The ledger (optional)

With no ledger the app is fully functional at the badge level. With one, the menu gains a live table
of your pipeline's gates. The format is deliberately trivial enough for any CI to produce with
`printf` — see §3.2 of the spec. Three rules it enforces, each one a defect already paid for:

- a gate declared in `EXPECTED` with no verdict file is **missing, and missing is a failure** — a
  step that silently stopped running must not look like one that passed;
- a ledger is valid **only for the run whose SHA it carries**, never "the freshest one";
- the table is ordered by **when gates actually ran**, never by the order they are declared in.

---

## The one-paragraph version

A CI notification fires on an **event**, which makes it structurally silent about the failure that
produces none: the pipeline that never ran. A runner that exits and is not restarted, a path filter
that swallows every push, a stuck queue — in all of those your last notification is still green and
still true, about a commit from three days ago. A badge shows a *current* state, so "nothing is
watching" gets a colour of its own. That is the half a notification cannot do.

## Why native, and not a SwiftBar plugin

A SwiftBar plugin already does most of this and is in daily use. It has one boundary that cannot be
moved: **SwiftBar builds its menu from a script's stdout and does not rebuild a menu already on
screen.** So the dropdown is a snapshot — a running gate's elapsed time does not tick while you
watch, and any click dismisses the menu.

That boundary is SwiftBar's, not macOS's. A native app owns its `NSMenu` and may mutate its items
while it is open; AppKit redraws them. That is why OneDrive's menu counts while you look at it, and
it is the entire reason for this project.

## Why its own repository

The pipeline this came from runs on a single self-hosted runner at `capacity: 1`, where one CI run
takes about twenty minutes. Keeping this app in that repository would put every one-line change to a
menu item behind a full iOS build in the same queue. It is also a general-purpose tool: it is meant
to watch several projects, and to be handed to other people.

## What already exists, and is proven

The pipeline side needs no new work. The ledger format the app reads — one file per gate, written by
a fifteen-line wrapper — is in production and is specified in §3.2 of the spec. It stays unchanged,
deliberately: the CI half is working and has no reason to churn while the UI is rebuilt.
