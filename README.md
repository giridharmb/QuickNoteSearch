# QuickNoteSearch

A fast, keyboard-driven menu-bar search for **Apple Notes** on macOS 14+.

<img src="Support/icon.png" width="128" alt="QuickNoteSearch icon">

- **Instant fuzzy search** over titles, folders and note bodies: prefix matching, one-typo tolerance, fuzzy title matching. Searches run in parallel across all CPU cores (~20 ms for 10,000 notes).
- **Hashtags**: `#work #urgent` (both), `#work|#home` (either), `-#archive` (exclude). Press ⇥ to autocomplete tags.
- **Live index** that stays in sync. It watches the Notes database with FSEvents, re-reads only the notes that changed, and is throttled so it stays idle when nothing changes.
- **Popup on a global hotkey** (default ⌥Space, configurable), with a preview pane that highlights matches.
- **Favourites** (⌘D), **recently opened** notes, **recent hashtags**, **bookmarked searches** (⌘S).
- **Per-note global hotkeys**: assign one from the preview pane or in Settings → Note Hotkeys.
- **Launch at login**, plus a detailed Settings window.

## Build

Requires Xcode 15+ / Swift 5.10+.

```bash
./scripts/build_app.sh            # → build/QuickNoteSearch.app
./scripts/build_app.sh --install  # also copies to /Applications and launches
swift test                        # unit tests (decoder, schema, search)
```

If an *Apple Development* or *Developer ID* certificate is in your keychain, the app is signed with it, so the Full Disk Access grant survives rebuilds. Otherwise it is signed ad-hoc and you must re-grant access after every rebuild. Set `SIGN_ID` to choose a specific identity.

## Permissions

| Permission | Why |
|---|---|
| **Full Disk Access** | Notes stores its data in `~/Library/Group Containers/group.com.apple.notes/NoteStore.sqlite`, which macOS protects. The app opens it **read-only**. |
| **Automation → Notes** | Used to ask Notes to show the note you picked. |

## Popup keys

| Key | Action |
|---|---|
| ↑ ↓ / ⌃N ⌃P / PgUp PgDn | Move selection |
| ↩ | Open in Notes |
| ⌘↩ | Copy note text |
| ⇥ | Complete `#tag` |
| ⌘D | Toggle favourite |
| ⌘S | Bookmark current search |
| ⌘1 / ⌘2 / ⌘3 | Recent / Favourites / All notes |
| ⎋ | Clear search, then close |
| ⌘, | Settings |

## How it works

`NoteStore.sqlite` is Notes' Core Data store. Each note body is a gzipped protobuf (`NoteStoreProto → Document → Note.note_text`). Hashtags are inline attachments (`com.apple.notes.inlinetextattachment.hashtag`). The schema is undocumented, so column names are checked at runtime. A Notes update that changes the format shows an error in Settings → Index instead of crashing.

The index lives **in memory only**. Writing note contents to a cache file would expose them to apps that don't have Full Disk Access. Favourites, history, bookmarks and hotkeys are stored in UserDefaults as note IDs only.

Limitations: the contents of locked (password-protected) notes are encrypted, so only their titles are searchable. The app never edits notes.
