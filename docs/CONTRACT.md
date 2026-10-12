# Stash's MacHUD contract

Stash implements the MacHUD contract through HUDKit; the canonical spec is HUDKit's
[docs/CONTRACT.md](https://github.com/jamesrisberg/hudkit/blob/main/docs/CONTRACT.md). MacHUD reads
`Stash.app/Contents/Resources/machud.json` without launching the app and talks to the running
app over a Unix socket.

The shared parts are specified there and not repeated here: [socket](https://github.com/jamesrisberg/hudkit/blob/main/docs/CONTRACT.md#socket) (location,
framing, replies), the [required verbs](https://github.com/jamesrisberg/hudkit/blob/main/docs/CONTRACT.md#verbs), [`subscribe`](https://github.com/jamesrisberg/hudkit/blob/main/docs/CONTRACT.md#subscribe-and-state-events),
the [settings schema](https://github.com/jamesrisberg/hudkit/blob/main/docs/CONTRACT.md#settings-schema) format, [hover and windowed behaviour](https://github.com/jamesrisberg/hudkit/blob/main/docs/CONTRACT.md#behaviour-hover-and-windowed),
the [launch announcement](https://github.com/jamesrisberg/hudkit/blob/main/docs/CONTRACT.md#launch-announcement) and [menu bar consolidation](https://github.com/jamesrisberg/hudkit/blob/main/docs/CONTRACT.md#menu-bar-consolidation).
This page lists what Stash adds.

- Manifest: `Sources/Stash/Resources/machud.json`: app `xyz.machud.stash`, socket `stash`, one
  panel `history` (`kind: hover`, `order: 2`, symbol `list.clipboard`, default 460x560, compact
  640x104, capabilities `providesDrag` and `text-feed`, verbs `show hide toggle frame mode paste`,
  settings schema `settings.json`), and the widget type `clips` (`kind: widget`, symbol
  `doc.on.clipboard`, sizes `small` and `medium`, default `small`, several instances,
  per-instance settings schema `clips.widget.json`). The widget has no dock button and no
  `panel` verbs: `panel show id=clips` answers `no such panel`, and `state` lists only `history`.
- Hover: `panel show from=<edge> anchor=x,y,w,h` slides the panel out of the dock (to the
  `panel frame` MacHUD assigned, else next to the anchor); `panel hide to=<edge>` slides it back
  in 0.1 s. `reason=hover` fades in over 0.08 s and never takes focus; other shows focus the
  search field. A show during a hide wins.
- Socket: `~/Library/Application Support/MacHUD/sockets/stash.sock` (0600), one JSON object per
  line: `{"command": "...", "args": {...}}` in, `{"ok": true, ...}` or `{"ok": false, "error": "..."}` out.
- CLI: `stash <command> [key=value ...]` (in `Stash.app/Contents/Helpers/stash`, linked onto PATH
  by `install.sh`). `stash action copy text=x` is shorthand for `action name=copy text=x`.
  `stash copy`, `list`, `paste`, `search`, `pin`, `delete` and `clear` are shorthands for the
  actions, `stash copy` with no text reads stdin, and `stash watch` prints state events.
  `stash snippets list query=sig` sends `{"command": "snippets", "args": {"_": "list", "query": "sig"}}`.

## Verbs

| Command | Args | Result |
|---|---|---|
| `hello` | | `{app, name, hudkit, version, panels, verbs}`: `hudkit` is the contract version, `version` the app's |
| `state` | | `{panels: [{id: "history", visible, mode, badge, status}]}`. `badge` is the number of clips in the history. `status` is `"<n> pinned"` (or `paused`), plus `, search: <q>` while a search is active. |
| `subscribe` | `events=state` (optional) | acknowledged, then `{"event": "state", "panels": [...]}` on visibility, mode or frame changes and on history changes. History changes are rate-limited to one event a second: the first goes out at once and a burst collapses into one trailing event. `stash watch` prints them. |
| `panel show` / `hide` / `toggle` | `id=history`, optional `from=`/`to=<edge>`, `anchor=x,y,w,h`, `reason=hover\|click\|summon` | fades in or out; `from=` slides out of the dock edge (to the `panel frame` MacHUD assigned, else next to `anchor`), `to=` slides back in 0.1 s; `reason=hover` fades in over 0.08 s and never takes focus, other shows focus the search field. A show during a hide wins |
| `panel frame` | `id=history x= y= w= h=` | AppKit screen coordinates, kept as the frame for the current mode |
| `panel mode` | `id=history` + `full`, `compact` or `parked` | `compact` is the strip of the five newest clips. `parked` slides the panel to the nearest screen edge, leaving a 14 pt sliver (or to `edge=left/right/top/bottom` with a `peek=` pt sliver when given, as MacHUD does; they are remembered for later bare `parked`s), and `show`/`toggle` slides it back (HUDKit `HUDParking`). Switching to `full` or `compact` shows the panel. |
| `settings get` | `key=` (optional) | `historyCap` (int), `pollIntervalMs` (int), `ignoreList` (comma-separated bundle ids), `pasteOnEnter` (bool), `ignoredFeedSources` (comma-separated labels), `snippetExpansion` (bool) |
| `settings set` | `key=value ...` | validates every value before applying any; saved to `preferences.json` |
| `settings schema` | | `{schema}` from `settings.json` via HUDKit's `HUDSettingsSchema` |
| `action copy` | `text=` | puts the text on the pasteboard and records it; returns `{count, id}` |
| `action copy-clip` | `index=` (1-based, 1 = newest; default 1) | what a click on a row does: puts the clip on the pasteboard (the private one under `STASH_PASTEBOARD`) without pasting, hiding the panel or reordering the history, and without recording it as a new clip. Returns `{copied, id, title, count, pasteboard}` |
| `action paste` | `index=` (1-based, 1 = newest; default 1) | copies the clip and sends ⌘V to the frontmost app. Returns `{copied, pasted, title}`. `pasted` is false, with a `hint`, when Accessibility is not granted or a private pasteboard is in use. |
| `action search` | `q=`, `limit=` (default 20) | sets the panel's search and returns `{total, results}` |
| `action list` | `limit=` (default 20) | `{total, results}`, newest first |
| `action pin` | `index=`, `on=true/false` (optional; toggles by default) | pins or unpins; pinned clips are exempt from the history cap |
| `action delete` | `index=` | removes the clip (and its blob) |
| `action clear` | `all=1` (optional) | removes unpinned clips, or everything with `all=1` |
| `action show` / `hide` / `toggle` | | same as the panel verbs |
| `feed` | `action=add text= source= title=?` `date=?` (ISO 8601) | HUDKit's `text-feed` capability (registered directly, like `sessions` for `agent-sessions`): records `text` as a history item tagged with `source` (a short label such as `Dictation`, shown with a small icon instead of an app name) rather than a pasteboard copy — the pasteboard is never touched, so the clipboard watcher never sees it. Searchable, pasteable, subject to the same cap as any clip. A `source` on `ignoredFeedSources` is accepted but not recorded (`id` comes back empty). Returns `{ok, id}` |
| `widget` | `action=create\|update\|remove\|list\|sync\|edit\|reveal\|schema` | HUDKit's widget verb for the `clips` type: MacHUD owns the instance records and sends them (`sync` after every connect), Stash draws them. See [Widgets](#widgets) below and HUDKit's [contract](https://github.com/jamesrisberg/hudkit/blob/main/docs/CONTRACT.md#widgets) for the verb, instance and event shapes. |
| `snippets list` | `query=` (optional), `limit=` (default 50) | `{snippets: [{id, name, keyword, collection, preview}]}`. `query` matches name, keyword and collection, case-insensitively, best first: keyword equal, keyword prefix, name prefix, a name word's prefix, keyword contains, name contains, collection contains; ties by collection, then name. No query lists every snippet by collection, then name. `preview` is the expanded text on one line, cut to 80 characters with `…`; `{date}` and `{time}` are filled in, `{clipboard}` stays as typed so a list never shows the clipboard. |
| `snippets insert` | `id=` | fills in the placeholders and pastes the text into the frontmost app 0.12 s later (after a panel or bar has closed), then restores the clipboard: `{ok: true, pasted: true}`. Without Accessibility, or with a private pasteboard, it copies the text only: `{ok: true, pasted: false, hint}`, with the hints `action paste` uses. Neither is recorded as a clip. `no snippet <id>` for an unknown id. |
| `snippets import-alfred` | `dry-run=1` (optional), `path=` (optional, a `snippets` folder; default Alfred's, following its synced-preferences setting) | reads Alfred's snippets and adds or updates them by Alfred's uid (never duplicating; snippets made in Stash are kept). `{dryRun, snippets, collections, byCollection: {name: count}, added, updated, unchanged, skipped, unknownPlaceholders: {token: count}}`; `dry-run=1` counts without writing. `skipped` counts unreadable `.json` files; `unknownPlaceholders` counts the `{…}` tokens left as typed by Alfred placeholder name (`cursor`, `snippet`, `date` for `{date:short}`, …) or `other`, never quoting a snippet's text. Collection names are reported as they are. |
| `snippets expansion` | `on`/`off` (or `state=`, `enabled=`; optional) | switches typed-keyword expansion (the `snippetExpansion` setting) and reports it: `{expansion: "on"\|"off", active, hint?}`. `active` is whether the key tap is running; `hint` says Accessibility is missing. |
| `quit` | | replies, then quits (the socket file is removed) |
| `help` | | lists the registered commands |

`snippets` is registered on the server directly (like `feed`); its action is the first bare word
(`_`) or `action=`.

Each result is `{index, id, kind, title, pinned, size, date, source?, feed?, paths?}`. `kind` is
`text`, `richText`, `image`, `files` or `url`. `source` is the bundle id of the app that was
frontmost when the clip was copied, or (with `feed: true`) the `text-feed` sender's label.

## Widgets

One widget type, `clips` (Latest Clips), registered on a `HUDWidgetHost` that is the router's
`widgetHost` before the socket starts.

| Size | Shows |
|---|---|
| `small` | the newest clip: type icon, age, a text preview (up to six lines) or a thumbnail and title for an image or file, a "Click to copy" hint |
| `medium` | the newest three clips as rows: type tile or thumbnail, one-line preview, age, a pin mark |

An instance's settings (schema `clips.widget.json`, read from `Contents/Resources`):
`pinnedOnly` (bool, default false) limits the list to pinned clips, newest first. With nothing to
show the widget says "Nothing copied yet" (or "No pinned clips").

A click on a clip runs the app's click-copy (the `copy-clip` action): the clip goes onto the
pasteboard (the private one under `STASH_PASTEBOARD`), the row shows "Copied" for 600 ms, and the
history order and count do not change. The widget never takes focus; it follows the history live
(it observes the app model), and `--snapshot-widgets <dir>` renders it for checking.

## Settings

| Key | Type | Default |
|---|---|---|
| `historyCap` | int (10-5000) | `200` |
| `pollIntervalMs` | int (50-5000) | `250` |
| `ignoreList` | string (comma-separated bundle ids) | password managers and Keychain Access |
| `pasteOnEnter` | bool | `true` |
| `snippetExpansion` | bool | `false` (typed keywords expand in place; needs Accessibility) |
| `ignoredFeedSources` | string (comma-separated `text-feed` source labels) | `""` (shows every source) |

Described by `Sources/Stash/Resources/settings.json` in HUDKit's `HUDSettingsSchema` format
(`{"version": 1, "settings": [{"key", "title", "type", "default"?, "help"?}]}`). Stored in
`<home>/preferences.json`, where home is `~/Library/Application Support/Stash` or `$STASH_HOME`.

## Snippets

Kept in `<home>/snippets.json` (`{"version": 1, "collections": [...], "snippets": [{id, name,
keyword, text, collection, autoExpand}]}`), rewritten atomically on every change. An imported
snippet's `id` is Alfred's uid. An unreadable file is moved aside (`snippets.unreadable-<time>.json`).

Expansion, while `snippetExpansion` is on: a session event tap (`.defaultTap`, which the
Accessibility permission allows; every event passes through unchanged) runs on its own thread
at the tail of the annotated session taps (`cgAnnotatedSessionEventTap`, `tailAppendEventTap`,
so it sees only keys other taps let through, annotated with their target application) and hands
each key, with the process it targets (`eventTargetUnixProcessID`), to the main thread. That
process is trusted whenever the event names one. A key that names none counts as typed in Stash
while one of Stash's windows has the keyboard (the hover panel takes keys without Stash being
frontmost), else as typed in the frontmost app. StashKit's `SnippetExpansionEngine` keeps up to 64 typed characters and resets on
navigation keys (arrows, Home, End, Page Up/Down, Tab, Return, Escape, Forward Delete), ⌘ or ⌃
shortcuts, Delete with any modifier, dead keys and the key after one, clicks, app switches and a
different target app. Nothing is kept while secure input is on, an input method is the selected
input source, or the target is an app on `ignoreList`, Stash or MacHUD (`com.jrisberg.machud`,
whose search bar finds snippets by keyword). Keywords match typed ASCII best. When the buffer
ends with an auto-expanding snippet's keyword (the longest wins; case-sensitive), Stash posts one
Delete per keyword character, puts the text on the clipboard (with Stash's marker and the
nspasteboard.org transient and concealed types), posts ⌘V, and restores the previous clipboard
0.3 s later (3 s for an Electron app) unless something else was copied since. One restore is
pending at a time: a snippet inserted before the previous one's restore (an expansion or
`snippets insert`) reuses the clipboard saved for it and replaces its restore. Stash types the
text as key events instead when it cannot paste (a private pasteboard, a clipboard over 16 MB, a
failed write; after a failed write the saved clipboard goes back at once). Every event Stash posts carries `eventSourceUserData` `0x53545348`, which the tap
ignores. Without Accessibility the tap is retried every 3 s.

## Menu bar consolidation

While MacHUD runs it shows Stash's status menu inside its own (`menu`, `menu-invoke`) and
the menu bar icon hides; it comes back when MacHUD quits or the user turns the
`menuBar.consumed` setting off (served by HUDKit's router, default `true`). The setting is
kept in `<home>/menubar.json` (home as for `preferences.json`, so `STASH_HOME` isolates it), never in the user's real preferences from a test instance.
See [menu bar consolidation](https://github.com/jamesrisberg/hudkit/blob/main/docs/CONTRACT.md#menu-bar-consolidation).

## Environment

| Variable | Read by | Effect |
|---|---|---|
| `STASH_HOME` | app | base directory for history, blobs, snippets, preferences and frames. |
| `STASH_SOCKET` | app, CLI | socket name or absolute path instead of `stash` |
| `STASH_NO_HOTKEYS` | app | `1` skips registering ⌃⌥V |
| `STASH_PASTEBOARD` | app | watch and write a private named pasteboard; simulated ⌘V is disabled then |
| `STASH_LOG_KEY_TARGET` | app | `1` logs, while expansion is on, the app each key goes to (process and bundle id, never what was typed), to check attribution |
| `STASH_INTEGRATION` | tests | `1` runs the general-pasteboard integration test |

An instance with any of `STASH_HOME`, `STASH_SOCKET` or `STASH_PASTEBOARD` set is isolated: it
never touches the user's defaults, and keeps panel frames only when it has its own home.

## Launch flags

| Flag | Effect |
|---|---|
| `--snapshot <path.png>` | show the panel and write a PNG of it after 2.5 s; with `--snapshot-widgets`, a snapshot run serves no control socket, announces nothing, does not watch the clipboard, registers no hotkey and adds no menu bar item, so it never touches a running instance |
| `--snapshot-quit` | quit after writing the snapshot |
| `--snapshot-mode compact` | picture the compact strip |
| `--snapshot-query <q>` | picture a search |
| `--snapshot-hover <n>` | draw clip n (1 = newest) as hovered |
| `--snapshot-snippets <path.png>` | show the Snippets window (first snippet selected) and write a PNG of it after 1.5 s; draws only, like `--snapshot` |
| `--demo` | sample clips and snippets in a throwaway history (or `$STASH_HOME`) on a private pasteboard |
| `--show` | show the panel at launch |

## Example

```sh
stash hello
stash panel show id=history
stash action copy text=hello
stash state                         # badge went up by one
echo "from a pipe" | stash copy
stash search pipe
stash paste 1
stash panel mode id=history compact
stash settings set historyCap=500 pasteOnEnter=false
stash feed action=add text="remind me to call back" source=Dictation
stash snippets import-alfred dry-run=1
stash snippets list query=sig limit=5
stash snippets insert id=<id>
stash snippets expansion on
stash watch
stash quit
```
