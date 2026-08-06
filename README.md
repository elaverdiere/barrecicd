# barrecicd

A macOS menu-bar item that shows CI state — and keeps beating while you look at it.

**Status:** specification only. No code yet.

Start with [`specs/S001-live-ci-status-bar.md`](specs/S001-live-ci-status-bar.md).

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
