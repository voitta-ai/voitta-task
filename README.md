# Voitta Task

macOS menu bar app that lists all active Claude Code sessions (terminal + VS Code)
and jumps to any of them with one click — raising the right window *and* the right
tab, then dismissing itself.

Features: live session list (name, first prompt, folder, host), type-to-filter
search, activity dots (green = working, gray = idle, flashing orange = likely
waiting for your approval), ESC or click-away to dismiss, panel grows with
content and scrolls past 75% of screen height.

## Requirements

- macOS 14 (Sonoma) or later, Apple Silicon or Intel
- Xcode Command Line Tools (`xcode-select --install`) — provides `swift` and
  `codesign`; Swift 5.9+
- Rust toolchain (`rustup`, stable) — https://rustup.rs
- Claude Code ≥ 2.x installed and in use (the app reads its on-disk state;
  developed against 2.1.207–2.1.209)

No Xcode project, no external package dependencies beyond crates.io
(`serde`, `serde_json`, `libc`) — first build downloads those automatically.

## Build & run

```bash
git clone https://github.com/voitta-ai/voitta-task.git
cd voitta-task
app/make-app.sh          # builds engine (cargo) + app (swiftpm), assembles bundle
open app/VoittaTask.app
```

Look for the ✳︎ icon in the menu bar. The bundle is self-contained; copy it to
/Applications if you want it permanent. To start at login: System Settings →
General → Login Items → add VoittaTask.app.

`make-app.sh` does, in order: `cargo build --release` in `engine/`,
`swift build -c release` in `app/`, then assembles `app/VoittaTask.app` with
the two binaries + the SwiftPM resource bundle (dog logo) + a generated
Info.plist (`LSUIElement` = menu-bar-only, no Dock icon), and ad-hoc codesigns
it (`codesign --sign -`). No paid developer certificate needed for local use;
distributing to other machines would require real signing + notarization.

### First-run permissions

Focusing a **terminal** session drives Terminal/iTerm via AppleScript, so
macOS shows a one-time Automation prompt ("VoittaTask wants to control
Terminal") — the app triggers it at launch (preflight) rather than on first
click. If it was ever denied: System Settings → Privacy & Security →
Automation → VoittaTask. Note the grant is tied to the app's identity; ad-hoc
re-signed builds keep it as long as the bundle id (`ai.voitta.task`) stays.

VS Code focusing needs no permissions.

### Dev loop

```bash
cd engine && cargo build --release && ./target/release/voitta-task-engine list   # engine alone
cd app && swift build                                                            # typecheck the UI
app/make-app.sh && pkill -f VoittaTask.app; open app/VoittaTask.app              # full cycle
```

Engine diagnostics land in `~/Library/Logs/VoittaTask.log` (every focus
attempt with the raw AppleScript result).

## Architecture

Native UI shell + headless engine:

```
engine/   Rust   voitta-task-engine — session discovery + focus actions (JSON CLI)
app/      Swift  VoittaTask — NSStatusItem + SwiftUI dropdown panel (SwiftPM, no Xcode)
```

The Swift app shells out to the engine binary bundled beside it in
`Contents/MacOS/` (falls back to `engine/target/release/` under `swift run`).

## Engine CLI

```bash
voitta-task-engine list              # JSON array of active sessions
voitta-task-engine focus <pid>       # raise that session's host UI
voitta-task-engine preflight <app>   # trigger the Automation permission prompt
```

## How sessions are discovered

Primary source: **`~/.claude/sessions/<pid>.json`** — a registry Claude Code
itself maintains per running process, containing `sessionId`, `cwd`, `name`
(the session name), `entrypoint` (`cli` vs `claude-vscode`), `status`,
timestamps. The engine validates each entry against the live process table:

1. PID alive (`kill(pid, 0)`).
2. Kernel process start time (`proc_pidinfo` / `PROC_PIDTBSDINFO`) within
   5 minutes of the registry's `startedAt` — rejects stale files and PID reuse.
3. Ancestor walk over a `ps` snapshot classifies the host UI:
   `Code Helper (Plugin)` → VS Code, `Terminal.app` / `iTerm.app` / Warp /
   Alacritty / kitty / WezTerm / Ghostty → that terminal. The registry's
   `entrypoint` is the fallback when ancestry is unreadable.

Session **title** (first real user prompt, same as Claude's `/resume` picker)
comes from the transcript at
`~/.claude/projects/<encoded-cwd>/<sessionId>.jsonl` (cwd encoded with
`/ . _` → `-`), falling back to `~/.claude/history.jsonl` (CLI sessions only).

Session **state** is derived, because only CLI sessions write `status` to the
registry (VS Code entries carry none):

- registry says non-idle → `working`; registry says `idle` → `idle`
- no registry status: transcript appended within 60 s → `working`, else `idle`
- override: transcript's last entry is an assistant `tool_use` with no result
  for 20 s+ → `waiting` (turn blocked — almost always a permission prompt;
  can also be a long-running tool). Only the last 256 KB of the transcript
  is read.

Other useful signals (not needed for v1, documented for later):
- `~/.claude/ide/<port>.lock` — one per IDE window with the Claude extension;
  contains workspace + `authToken` for its localhost WebSocket. The embedded
  `pid` field is unreliable; verify liveness by connecting to the port.

## How focus works

**Terminal (Terminal.app / iTerm2):** the engine knows the session's tty
(from the `ps` snapshot). AppleScript iterates windows/tabs, matches `tty`,
selects the tab, raises the window, activates the app. Windows without tabs
(e.g. Settings) are skipped — asking them for tabs aborts the whole script.
Other terminals (Warp, kitty, …) are recognized but only activated app-level.

**VS Code / Cursor:** two steps, ordering matters:
1. `open -a "Visual Studio Code" <cwd>` — macOS focuses the existing window
   that has that folder open.
2. `open "vscode://anthropic.claude-code/open?session=<sessionId>"` — the
   Claude extension registers a URI handler whose `/open` path runs
   `claude-vscode.primaryEditor.open` with the session id, focusing/opening
   that exact session tab. URIs route to the focused window, hence step 1 first.

## Known limitations (v1)

- All of `~/.claude/sessions/`, the URI handler, and the transcript format are
  undocumented Claude Code internals and may shift between releases; each
  signal degrades independently (worst case: a session lists but won't focus).
- If a VS Code workspace window shows a different folder than the session cwd
  (e.g. git worktrees), step 1 of the VS Code focus may pick another window.
- `waiting` can't distinguish a pending approval from a long-running tool —
  both look like an unresolved tool call in the transcript.
- Focus of terminal tabs is implemented for Terminal.app and iTerm2 only.

## License

AGPL-3.0 — see [LICENSE](LICENSE).
