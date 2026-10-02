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

## Verbs

| Command | Args | Result |
|---|---|---|
| `hello` | | `{app, name, hudkit, version, panels, verbs}`: `hudkit` is the contract version, `version` the app's |
| `state` | | `{panels: [{id: "history", visible, mode, badge, status}]}`. `badge` is the number of clips in the history. `status` is `"<n> pinned"` (or `paused`), plus `, search: <q>` while a search is active. |
| `subscribe` | `events=state` (optional) | acknowledged, then `{"event": "state", "panels": [...]}` on visibility, mode or frame changes and on history changes. History changes are rate-limited to one event a second: the first goes out at once and a burst collapses into one trailing event. `stash watch` prints them. |
| `panel show` / `hide` / `toggle` | `id=history`, optional `from=`/`to=<edge>`, `anchor=x,y,w,h`, `reason=hover\|click\|summon` | fades in or out; `from=` slides out of the dock edge (to the `panel frame` MacHUD assigned, else next to `anchor`), `to=` slides back in 0.1 s; `reason=hover` fades in over 0.08 s and never takes focus, other shows focus the search field. A show during a hide wins |
| `panel frame` | `id=history x= y= w= h=` | AppKit screen coordinates, kept as the frame for the current mode |
| `panel mode` | `id=history` + `full`, `compact` or `parked` | `compact` is the strip of the five newest clips. `parked` slides the panel to the nearest screen edge, leaving a 14 pt sliver (or to `edge=left/right/top/bottom` with a `peek=` pt sliver when given, as MacHUD does; they are remembered for later bare `parked`s), and `show`/`toggle` slides it back (HUDKit `HUDParking`). Switching to `full` or `compact` shows the panel. |
| `settings get` | `key=` (optional) | `historyCap` (int), `pollIntervalMs` (int), `ignoreList` (comma-separated bundle ids), `pasteOnEnter` (bool) |
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
| `quit` | | replies, then quits (the socket file is removed) |
| `help` | | lists the registered commands |

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
| `ignoredFeedSources` | string (comma-separated `text-feed` source labels) | `""` (shows every source) |

Described by `Sources/Stash/Resources/settings.json` in HUDKit's `HUDSettingsSchema` format
(`{"version": 1, "settings": [{"key", "title", "type", "default"?, "help"?}]}`). Stored in
`<home>/preferences.json`, where home is `~/Library/Application Support/Stash` or `$STASH_HOME`.

## Menu bar consolidation

While MacHUD runs it shows Stash's status menu inside its own (`menu`, `menu-invoke`) and
the menu bar icon hides; it comes back when MacHUD quits or the user turns the
`menuBar.consumed` setting off (served by HUDKit's router, default `true`). The setting is
kept in `<home>/menubar.json` (home as for `preferences.json`, so `STASH_HOME` isolates it), never in the user's real preferences from a test instance.
See [menu bar consolidation](https://github.com/jamesrisberg/hudkit/blob/main/docs/CONTRACT.md#menu-bar-consolidation).

## Environment

| Variable | Read by | Effect |
|---|---|---|
| `STASH_HOME` | app | base directory for history, blobs, preferences and frames. |
| `STASH_SOCKET` | app, CLI | socket name or absolute path instead of `stash` |
| `STASH_NO_HOTKEYS` | app | `1` skips registering ⌃⌥V |
| `STASH_PASTEBOARD` | app | watch and write a private named pasteboard; simulated ⌘V is disabled then |
| `STASH_INTEGRATION` | tests | `1` runs the general-pasteboard integration test |

An instance with any of `STASH_HOME`, `STASH_SOCKET` or `STASH_PASTEBOARD` set is isolated: it
never touches the user's defaults, and keeps panel frames only when it has its own home.

## Launch flags

| Flag | Effect |
|---|---|
| `--snapshot <path.png>` | show the panel and write a PNG of it after 2.5 s |
| `--snapshot-quit` | quit after writing the snapshot |
| `--snapshot-mode compact` | picture the compact strip |
| `--snapshot-query <q>` | picture a search |
| `--snapshot-hover <n>` | draw clip n (1 = newest) as hovered |
| `--demo` | sample clips in a throwaway history (or `$STASH_HOME`) on a private pasteboard |
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
stash watch
stash quit
```
