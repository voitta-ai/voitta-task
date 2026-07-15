# ClaudeBar

macOS menu bar app that lists all active Claude Code sessions (terminal + VS Code)
and jumps to any of them with one click — raising the right window *and* the right
tab, then dismissing itself.

## Architecture

Mirrors the SafeClaude split: a native UI shell + a headless engine.

```
engine/   Rust   claudebar-engine — session discovery + focus actions (JSON CLI)
app/      Swift  ClaudeBar — NSStatusItem + SwiftUI dropdown panel
```

Build everything into `app/ClaudeBar.app`:

```bash
app/make-app.sh
open app/ClaudeBar.app
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

Other useful signals (not needed for v1, documented for later):
- `~/.claude/ide/<port>.lock` — one per IDE window with the Claude extension;
  contains workspace + `authToken` for its localhost WebSocket. The embedded
  `pid` field is unreliable; verify liveness by connecting to the port.
- `~/.claude/projects/<encoded-cwd>/<uuid>.jsonl` — transcripts; mtime is a
  live activity indicator.
- `~/.claude/history.jsonl` — sessionId → first prompt text.

## How focus works

**Terminal (Terminal.app / iTerm2):** the engine knows the session's tty
(`ps -o tty=`). AppleScript iterates windows/tabs, matches `tty`, selects the
tab, raises the window, activates the app. First use triggers a one-time
Automation permission prompt (ClaudeBar → Terminal/iTerm).

**VS Code / Cursor:** two steps, ordering matters:
1. `open -a "Visual Studio Code" <cwd>` — macOS focuses the existing window
   that has that folder open.
2. `open "vscode://anthropic.claude-code/open?session=<sessionId>"` — the
   Claude extension registers a URI handler whose `/open` path runs
   `claude-vscode.primaryEditor.open` with the session id, focusing/opening
   that exact session tab. URIs route to the focused window, hence step 1 first.

## Engine CLI

```bash
claudebar-engine list          # JSON array of active sessions
claudebar-engine focus <pid>   # raise that session's host UI
```

## Known limitations (v1)

- All of `~/.claude/sessions/`, the URI handler, and the lock-file format are
  undocumented Claude Code internals and may shift between releases; each
  signal degrades independently.
- If a VS Code workspace window shows a different folder than the session cwd
  (e.g. git worktrees), step 1 of the VS Code focus may pick another window.
- `status` in the registry is only as fresh as Claude Code writes it; sessions
  without a status show a green (assumed-active) dot.
