# QuotaBar

QuotaBar is a macOS menu bar app that helps you track Codex quota usage from the menu bar and move selected Codex threads between devices, without juggling multiple terminals, browser sessions, or shared local state.

It is a good fit if you want:

* a status bar app instead of a full desktop window
* multiple Codex accounts under one app
* isolated account storage without touching the default `~/.codex`
* quick visibility into the current 5-hour and weekly remaining quota
* a simple way to carry selected Codex threads and session state between machines

## Screenshots

### Menu Bar Panel

<img src="./menu-panel.jpeg" alt="CodexBar menu screenshot" width="480" />

### Settings

<img src="./settings.jpeg" alt="QuotaBar settings screenshot" width="480" />

## What It Does

QuotaBar currently supports:

* multiple Codex accounts for a single provider
* browser-based `codex login` in an isolated temporary `CODEX_HOME`
* manual `auth.json` import
* secure auth blob storage in Keychain
* per-account metadata storage in SwiftData
* menu bar monitoring panel
* manual refresh
* background refresh every 30 minutes
* single-session backup export/import for continuing work across devices

The monitoring panel shows:

* account email
* plan tag
* 5-hour remaining quota
* weekly remaining quota
* short reset timestamps
* account health state

## How It Works

QuotaBar keeps account auth isolated from the default `~/.codex`, but the backup tools can read your real Codex session data when you explicitly use the backup flow.

Each account is handled like this:

1. Login runs in an app-managed isolated `CODEX_HOME`
2. The resulting `auth.json` is stored in Keychain
3. Non-sensitive account metadata is stored in SwiftData
4. Refresh extracts a bearer token from the stored auth blob
5. Usage is fetched from:

```text
https://chatgpt.com/backend-api/wham/usage
```

QuotaBar maps that response into:

* 5h remaining
* weekly remaining
* reset times
* plan type

The backup flow is separate from account monitoring:

1. You choose one or more visible Codex threads to export
2. QuotaBar reads the matching thread metadata and rollout files from your real `~/.codex`
3. It writes a compressed backup archive
4. On another machine, you choose that archive and remap each project to a local workspace before import

## Storage Model

Sensitive data:

* full `auth.json` per account
* stored in macOS Keychain

Non-sensitive data:

* display name
* email
* remote account id
* plan type
* enabled/disabled state
* sync timestamps
* stored in SwiftData

Backup-related data:

* exported archives are written only to the folder you choose
* session import/export reads thread metadata from `~/.codex/state_5.sqlite`
* session import/export reads and writes rollout files under `~/.codex/sessions` and `~/.codex/archived_sessions`
* backup does not copy account auth, Keychain items, or unrelated sessions

## Requirements

* macOS
* Xcode 16+
* an installed `codex` CLI available to the app

## Run Locally

Open the project in Xcode:

```bash
open QuotaBar.xcodeproj
```

Or build from Terminal:

```bash
xcodebuild \
  -project QuotaBar.xcodeproj \
  -scheme QuotaBar \
  -configuration Debug \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  build
```

## Distribution / Release

QuotaBar is intended for `Developer ID` direct distribution, not Mac App Store distribution.

That means:

* the app stays `unsandboxed`
* it can continue to access the user-installed `codex` CLI
* distribution should use `Developer ID Application` signing plus notarization

Before releasing:

* keep `ENABLE_APP_SANDBOX = NO`
* keep `LSUIElement = YES`
* make sure the release machine has a valid `Developer ID Application` certificate

Recommended release flow:

1. Archive, sign, notarize, and export `QuotaBar.app` manually from Xcode
2. Put the exported app at `dist/QuotaBar.app`
3. Run:

```bash
scripts/build-dmg.sh
```

The DMG script only packages an existing exported app. It does not archive, sign, or notarize for you.

If the exported app is elsewhere:

```bash
scripts/build-dmg.sh --app /path/to/QuotaBar.app
```

## Codex Session Portability

QuotaBar includes an in-app backup flow for the common case where you start a Codex thread on one machine and want to continue it on another machine without syncing your entire `~/.codex` directory or account state.

This solves:

* moving a single active thread between home and work machines
* exporting only the projects and threads you care about
* remapping imported threads onto a different local checkout path on another device
* avoiding accidental sync of auth files, unrelated sessions, or global Codex config

In-app workflow:

1. Open `Settings -> Backup`
2. Set an `Export Folder`
3. Choose `Select Threads To Export`
4. Pick one or more threads grouped by workspace
5. Export them into one compressed `.zip` archive
6. Move that archive to the target machine
7. On the target machine, open `Settings -> Backup`
8. Choose the backup `.zip`
9. For each detected project, select the destination local workspace
10. Import the backup

Important behavior:

* the export list tries to match the Codex app sidebar, not every row in the SQLite database
* archived threads are excluded
* only threads with a user-facing indexed title are shown
* opening the export dialog refreshes the thread list from `~/.codex`
* import rewrites each thread's workspace path to the folder you choose for that project

Use this flow when your code is already synced by Git and you only need the Codex conversation/session state.

This repo includes two helper scripts for moving a single Codex session between devices without syncing the entire `~/.codex` directory.

Scripts:

* `/Users/aidan/dev/apps/QuotaBar/scripts/codex_session_export.py`
* `/Users/aidan/dev/apps/QuotaBar/scripts/codex_session_import.py`

The scripts do not assume a default sync directory. Pass an explicit export directory so the app or your shell scripts can decide whether to use iCloud Drive, a local folder, a mounted volume, or a VPS staging path.

Export the most recently updated session:

```bash
./scripts/codex_session_export.py --output-dir "/path/to/session-bundles"
```

Export a specific session id to a custom directory:

```bash
./scripts/codex_session_export.py 019cfc28-8892-7840-a6d1-8d614da18358 --output-dir /tmp/codex-bundles
```

Import a bundle on another machine:

```bash
./scripts/codex_session_import.py "/path/to/bundle"
```

If the repo lives at a different path on the target machine, pass `--cwd`:

```bash
./scripts/codex_session_import.py "/path/to/bundle" --cwd /path/to/QuotaBar
```

These scripts move only the selected session's rollout JSONL and thread metadata. They do not sync auth, global settings, or unrelated sessions. Close Codex before export/import to avoid SQLite WAL state drifting during the copy.

## Notes

* This is not an official OpenAI product.
* The usage endpoint and auth format are not stable public APIs and may change.
* API-key-only auth is not supported for quota monitoring. A ChatGPT/Codex bearer token is required.
* Direct distribution is the supported release model for this project today.

## Privacy

QuotaBar is built to minimize account cross-contamination:

* it does not reuse the default `~/.codex`
* each account is stored independently
* refresh uses the account’s own stored auth blob

## Project Status

Current scope is intentionally narrow:

* one provider: Codex
* one menu bar monitor
* multi-account support first

More providers can be added later behind the same account/service model.

## License

MIT. See [LICENSE](/Users/aidan/dev/app/QuotaBar/LICENSE).
