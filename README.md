# Stash

A clipboard manager for macOS, and a sibling of [Sift](../sift) in the MacHUD family. macOS 14+.

## What it is

Stash lives in the menu bar (no Dock icon) and keeps a searchable history of what you copy:
text, rich text, images, files and links, with pinned clips and a compact strip of the last
five. On its own it shows its panel from the menu bar icon or ⌃⌥V; inside MacHUD it is a hover
button in the tool dock (order 2, after Scratch) whose panel slides out while the pointer is
over it.

## Install

Check out HUDKit (the shared kit and build scripts) and Sift (Stash uses its FileKit for
thumbnails and file actions) next to this repo, then install:

```sh
ls ~/dev            # hudkit  sift  stash
~/dev/stash/install.sh
```

`install.sh` builds a release, quits a running copy, installs `/Applications/Stash.app`, links
the `stash` command onto your PATH and launches it.

## Use

| Key | Does |
|---|---|
| ⌃⌥V | show or hide the panel; the search field has focus, so just type |
| ↑ ↓ | move |
| ↩ | paste into the app you were in |
| ⌘C | copy only |
| ⌘P | pin or unpin |
| ⌫ (⌘⌫ while searching) | delete |
| esc | clear the search, then close |

- **Click** a clip to copy it back onto the clipboard: the row flashes "Copied", the panel
  stays open and the list keeps its order (Stash does not record its own copy as a new
  clip). Hovering a row lifts it and shows "Click to copy · ⏎ paste".
- **Double-click** pastes, **⌘-click** pins or unpins, drag one out to drop its text, link,
  file or image anywhere, and right-click a file clip to copy it into one of Sift's targets.
- The compact strip shows the five newest clips side by side, with the same clicks. Switch
  with the button in the corner or the menu bar menu.

The menu bar icon's menu has Show Stash, Compact Strip, Pause Recording, Enter Pastes into
Previous App, Grant Accessibility…, Clear History (Keep Pinned), Reveal History Folder and Quit.
In the MacHUD dock, hover the button to see the panel. Stash takes no drops; its panel is a
drag source (`providesDrag`).

Pasting sends a simulated ⌘V, which needs Accessibility (menu bar icon > Grant
Accessibility…). Without it, Stash copies the clip and shows a hint instead.

## Privacy

Nothing leaves your Mac. History is stored in `~/Library/Application Support/Stash`
(`history.json` plus `blobs/` for images and rich text, `preferences.json` and `frames.json`).
Stash does not record a copy when:

- secure input is on (a password field has focus; `IsSecureEventInputEnabled()`),
- the frontmost app is on the ignore list (1Password, Bitwarden, LastPass, Dashlane,
  KeePassXC, Enpass, Keychain Access and Passwords by default),
- the copying app marks the content as concealed, transient or auto-generated
  ([nspasteboard.org](http://nspasteboard.org) types),
- recording is paused from the menu.

## MacHUD contract

Panel `history`, kind `hover`, socket `stash`. Verbs: the HUDKit set (`hello`, `state`,
`subscribe`, `panel show|hide|toggle|frame|mode`, `settings get|set|schema`, `action`, `quit`)
plus `action copy`, `copy-clip`, `paste`, `search`, `list`, `pin`, `delete` and `clear`. Full
reference: [docs/CONTRACT.md](docs/CONTRACT.md).

```sh
stash list                    # history with indexes, newest first
echo "some text" | stash copy # copy stdin (or: stash copy some text)
stash paste 2                 # paste the second newest clip into the frontmost app
stash search invoice
stash panel mode id=history compact
stash watch                   # state events (badge = clip count)
```

## Settings

| Key | Type | Default | |
|---|---|---|---|
| `historyCap` | int | `200` | unpinned clips kept (10-5000); pinned clips are exempt |
| `pollIntervalMs` | int | `250` | how often the pasteboard is checked (50-5000) |
| `ignoreList` | string | password managers | comma-separated bundle ids whose copies are never recorded |
| `pasteOnEnter` | bool | `true` | ↩ pastes into the previous app; off, it only copies |

Set them in MacHUD's settings window (which reads `settings.json`) or with
`stash settings set key=value`. Stored in `~/Library/Application Support/Stash/preferences.json`.

## Build from source

Needs Swift 5.9+ with HUDKit (`../hudkit`) and Sift (`../sift`) checked out next to this repo.

```sh
swift test                         # StashKitTests + StashTests; never touches the system clipboard
STASH_INTEGRATION=1 swift test     # also the one general-pasteboard test (saves and restores it)
./build.sh                         # build/Stash.app (release; ./build.sh debug for a debug build)
./install.sh                       # build, install to /Applications, link the CLI, launch
build/Stash.app/Contents/MacOS/Stash --demo --snapshot /tmp/full.png --snapshot-quit
build/Stash.app/Contents/MacOS/Stash --demo --snapshot /tmp/strip.png --snapshot-mode compact --snapshot-quit
```

`--snapshot <png>` writes a picture of the panel without Screen Recording permission. It
takes `--snapshot-mode compact`, `--snapshot-query <q>` and `--snapshot-hover <n>` (draws
clip n, 1 = newest, as hovered), and quits after with `--snapshot-quit`. `--demo` fills a
throwaway history with sample clips on a private pasteboard.

`build.sh` and `install.sh` call HUDKit's shared `scripts/hud-build.sh` and
`scripts/hud-install.sh` (set `HUDKIT_DIR` if HUDKit lives elsewhere). The version comes from
[VERSION](VERSION); changes are in [CHANGELOG.md](CHANGELOG.md).

Layout: `Sources/StashKit` is the UI-free core (`ClipboardWatcher`, `Clip`, `ClipReader`,
`ClipStore`, `StashSettings`, `EventThrottle`). `Sources/Stash` is the app (bundle files in
`Sources/Stash/Resources`), `Sources/StashCLI` the `stash` CLI, and `Tests/` covers StashKit,
the app's host logic (click-copy, hover chrome, parking, frames, environment) and the manifest.

## Isolation env vars for testing

| Variable | Effect |
|---|---|
| `STASH_HOME` | base directory for history, blobs, preferences and frames (default `~/Library/Application Support/Stash`). |
| `STASH_SOCKET` | socket name or absolute path (default `stash`); the CLI honours it too |
| `STASH_NO_HOTKEYS` | `1` skips registering ⌃⌥V |
| `STASH_PASTEBOARD` | watch and write a private named pasteboard instead of the general one; simulated ⌘V is disabled then |

```sh
STASH_HOME=$(mktemp -d) STASH_SOCKET=stash-test STASH_PASTEBOARD=stash-test STASH_NO_HOTKEYS=1 \
  build/Stash.app/Contents/MacOS/Stash &
STASH_SOCKET=stash-test build/Stash.app/Contents/Helpers/stash hello
STASH_SOCKET=stash-test build/Stash.app/Contents/Helpers/stash quit
```

## License

MIT, see [LICENSE](LICENSE).
