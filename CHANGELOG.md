# Changelog

All notable changes to Stash are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/); the current version is in [VERSION](VERSION).

## [Unreleased]

## [0.1.0] - 2026-09-27

First release: a clipboard history for macOS 14+ in the MacHUD family, built on HUDKit.

### Added
- StashKit, the UI-free core: a clipboard watcher that skips secure input, ignored apps
  (password managers and Keychain Access by default) and concealed, transient or
  auto-generated content; a clip model for text, rich text, images, files and links; a
  persistent history (`history.json` plus `blobs/`) with pinned clips exempt from a cap;
  settings; an event throttle.
- Stash, a menu bar app (no Dock icon) with a history panel on HUD glass: search, keyboard
  navigation and paste (⌃⌥V toggles; ↩ pastes into the app you were in via a simulated ⌘V,
  which needs Accessibility), pin, delete, drag out, Sift targets for file clips, and a
  compact strip of the five newest clips. A click copies a clip back without pasting,
  closing or reordering; rows lift on hover with a "Click to copy · ⏎ paste" hint.
- Menu bar menu: Show Stash, Compact Strip, Pause Recording, Enter Pastes into Previous App,
  Grant Accessibility…, Clear History (Keep Pinned), Reveal History Folder and Quit. App and
  menu bar icons from the MacHUD family set, with an SF Symbol fallback for the status item.
- MacHUD contract: `machud.json` (panel `history`, `kind: hover`, order 2 in the dock after
  Scratch, `providesDrag`), `settings.json` schema (`historyCap`, `pollIntervalMs`,
  `ignoreList`, `pasteOnEnter`), and the HUDKit socket verbs plus the `copy`, `copy-clip`,
  `paste`, `search`, `list`, `pin`, `delete` and `clear` actions. `hello` reports the app's
  `version` and `statusItem`.
- Hover panel that slides out of MacHUD's dock edge and back (a show during a hide wins),
  with quick fades, a close button, a drag header and frames kept in `frames.json`.
  `panel mode parked` parks it at the screen edge, or at the edge and peek MacHUD asks for.
- Menu bar consolidation: while MacHUD runs, Stash's menu appears in MacHUD's status menu
  (`menu`, `menu-invoke`) and its own icon hides; opt out with
  `settings set menuBar.consumed=false`, kept in `<home>/menubar.json`.
- `stash` CLI with `copy` (text or stdin), `list`, `paste`, `search`, `pin`, `delete`,
  `clear` and `watch` shorthands.
- Isolated test instances via `STASH_HOME`, `STASH_SOCKET`, `STASH_PASTEBOARD` and
  `STASH_NO_HOTKEYS`; `--demo` and `--snapshot` for visual checks without Screen Recording.
- Builds and installs through HUDKit's `hud-build.sh` / `hud-install.sh`.
