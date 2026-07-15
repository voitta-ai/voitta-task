// claudebar-engine: enumerate active Claude Code sessions on macOS and
// bring a chosen one to the foreground (terminal tab or VS Code window+tab).
//
//   claudebar-engine list          -> JSON array of active sessions
//   claudebar-engine focus <pid>   -> raise that session's host UI
//
// Primary data source is ~/.claude/sessions/<pid>.json, a registry Claude
// Code maintains for every running process. Entries are validated against
// the live process table (PID alive + start-time match) to reject stale
// files and PID reuse.

use serde::{Deserialize, Serialize};
use std::path::PathBuf;
use std::process::Command;

// ---------- registry file (~/.claude/sessions/<pid>.json) ----------

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct RegistryEntry {
    pid: i32,
    session_id: String,
    cwd: String,
    started_at: i64, // ms epoch
    #[serde(default)]
    version: Option<String>,
    #[serde(default)]
    kind: Option<String>,
    #[serde(default)]
    entrypoint: Option<String>,
    #[serde(default)]
    name: Option<String>,
    #[serde(default)]
    status: Option<String>,
    #[serde(default)]
    updated_at: Option<i64>,
}

// ---------- output ----------

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct Session {
    pid: i32,
    session_id: String,
    name: String,
    cwd: String,
    /// "vscode" | "cursor" | "terminal" | "unknown"
    host: String,
    /// Human label of the hosting app, e.g. "Visual Studio Code", "Terminal", "iTerm2"
    host_app: String,
    kind: String,
    status: String,
    version: String,
    started_at: i64,
    updated_at: i64,
    /// e.g. "/dev/ttys009" for terminal sessions (needed to focus the tab)
    tty: Option<String>,
    /// First real user prompt of the session (what `/resume` shows).
    title: Option<String>,
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    match args.get(1).map(String::as_str) {
        Some("list") => {
            let sessions = scan();
            println!("{}", serde_json::to_string_pretty(&sessions).unwrap());
        }
        Some("focus") => {
            let pid: i32 = args
                .get(2)
                .and_then(|s| s.parse().ok())
                .unwrap_or_else(|| die("usage: claudebar-engine focus <pid>"));
            let sessions = scan();
            let Some(s) = sessions.iter().find(|s| s.pid == pid) else {
                die(&format!("no active session with pid {pid}"));
            };
            match focus(s) {
                Ok(how) => {
                    log_line(&format!("focus pid={pid} ok: {how}"));
                    println!("{{\"ok\":true,\"how\":\"{how}\"}}");
                }
                Err(e) => {
                    log_line(&format!("focus pid={pid} FAILED: {e}"));
                    println!("{}", serde_json::json!({"ok": false, "error": e}));
                    std::process::exit(1);
                }
            }
        }
        // Trigger the macOS Automation permission prompt for the given
        // terminal app (run once at app startup so denial isn't silent).
        Some("preflight") => {
            let app = args.get(2).map(String::as_str).unwrap_or("Terminal");
            let script = format!("tell application \"{app}\" to count windows");
            let out = Command::new("/usr/bin/osascript")
                .args(["-e", &script])
                .output();
            match out {
                Ok(o) if o.status.success() => {
                    log_line(&format!("preflight {app}: ok"));
                    println!("{{\"ok\":true}}");
                }
                Ok(o) => {
                    let err = String::from_utf8_lossy(&o.stderr).trim().to_string();
                    log_line(&format!("preflight {app}: DENIED/ERROR: {err}"));
                    println!("{}", serde_json::json!({"ok": false, "error": err}));
                }
                Err(e) => {
                    log_line(&format!("preflight {app}: spawn error {e}"));
                    println!("{}", serde_json::json!({"ok": false, "error": e.to_string()}));
                }
            }
        }
        _ => die("usage: claudebar-engine <list|focus PID>"),
    }
}

fn die(msg: &str) -> ! {
    eprintln!("{msg}");
    std::process::exit(2);
}

/// Append a diagnostic line to ~/Library/Logs/ClaudeBar.log.
fn log_line(msg: &str) {
    use std::io::Write;
    let path = home().join("Library/Logs/ClaudeBar.log");
    if let Ok(mut f) = std::fs::OpenOptions::new().create(true).append(true).open(path) {
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_secs())
            .unwrap_or(0);
        let _ = writeln!(f, "[{now}] {msg}");
    }
}

// ---------- scan ----------

fn scan() -> Vec<Session> {
    let dir = home().join(".claude/sessions");
    let mut out = Vec::new();
    let Ok(entries) = std::fs::read_dir(&dir) else {
        return out;
    };
    let table = process_table();
    let titles = session_titles();
    for e in entries.flatten() {
        let p = e.path();
        if p.extension().and_then(|x| x.to_str()) != Some("json") {
            continue;
        }
        let Ok(text) = std::fs::read_to_string(&p) else {
            continue;
        };
        let Ok(r) = serde_json::from_str::<RegistryEntry>(&text) else {
            continue;
        };
        if !pid_alive(r.pid) {
            continue;
        }
        // Reject PID reuse: kernel start time must be near the registry's
        // startedAt (session start follows process start within seconds).
        if let Some(kstart) = proc_start_epoch(r.pid) {
            if (kstart - r.started_at / 1000).abs() > 300 {
                continue;
            }
        }
        let (mut host, mut host_app) = classify_host(r.pid, &table);
        if host == "unknown" {
            // Ancestry walk failed (e.g. orphaned process) — fall back to
            // what claude itself recorded about how it was launched.
            match r.entrypoint.as_deref() {
                Some("claude-vscode") => {
                    host = "vscode".into();
                    host_app = "Visual Studio Code".into();
                }
                Some("cli") => {
                    host = "terminal".into();
                }
                _ => {}
            }
        }
        let tty = if host == "terminal" {
            table.get(&r.pid).and_then(|p| p.tty.clone())
        } else {
            None
        };
        let title = transcript_title(&r.cwd, &r.session_id)
            .or_else(|| titles.get(&r.session_id).cloned());
        out.push(Session {
            pid: r.pid,
            name: r.name.unwrap_or_else(|| r.session_id.clone()),
            title,
            session_id: r.session_id,
            cwd: r.cwd,
            host,
            host_app,
            kind: r.kind.unwrap_or_default(),
            status: r.status.unwrap_or_default(),
            version: r.version.unwrap_or_default(),
            started_at: r.started_at,
            updated_at: r.updated_at.unwrap_or(r.started_at),
            tty,
        });
    }
    // Most recently active first.
    out.sort_by_key(|s| -s.updated_at);
    out
}

/// First real user prompt from the session transcript
/// (~/.claude/projects/<encoded-cwd>/<sessionId>.jsonl). Streams lines and
/// stops at the first genuine user message, so large transcripts stay cheap.
fn transcript_title(cwd: &str, session_id: &str) -> Option<String> {
    use std::io::BufRead;
    let encoded: String = cwd
        .chars()
        .map(|c| if c == '/' || c == '.' || c == '_' { '-' } else { c })
        .collect();
    let projects = home().join(".claude/projects");
    let mut path = projects.join(&encoded).join(format!("{session_id}.jsonl"));
    if !path.exists() {
        // Session may have been started from a different directory than its
        // current cwd — search every project folder for the transcript.
        path = std::fs::read_dir(&projects)
            .ok()?
            .flatten()
            .map(|e| e.path().join(format!("{session_id}.jsonl")))
            .find(|p| p.exists())?;
    }
    let f = std::fs::File::open(path).ok()?;
    let mut reader = std::io::BufReader::new(f);
    let mut line = String::new();
    for _ in 0..5000 {
        line.clear();
        if reader.read_line(&mut line).ok()? == 0 {
            return None;
        }
        let Ok(v) = serde_json::from_str::<serde_json::Value>(&line) else {
            continue;
        };
        if v.get("type").and_then(|t| t.as_str()) != Some("user")
            || v.get("isMeta").and_then(|b| b.as_bool()) == Some(true)
        {
            continue;
        }
        let content = v.get("message").and_then(|m| m.get("content"));
        let text = match content {
            Some(serde_json::Value::String(s)) => s.clone(),
            Some(serde_json::Value::Array(blocks)) => blocks
                .iter()
                .find_map(|b| {
                    (b.get("type")?.as_str()? == "text").then(|| b.get("text"))?
                })
                .and_then(|t| t.as_str())
                .unwrap_or_default()
                .to_string(),
            _ => continue,
        };
        let t = text.trim();
        // Skip command wrappers (<command-name>…), tool results, shell/meta
        // prompts — they don't describe the session.
        if t.is_empty() || t.starts_with('<') || t.starts_with('/') || t.starts_with('!') {
            continue;
        }
        let mut title = t.replace('\n', " ");
        if let Some((i, _)) = title.char_indices().nth(160) {
            title.truncate(i);
            title.push('…');
        }
        return Some(title);
    }
    None
}

/// sessionId -> first real user prompt, from ~/.claude/history.jsonl.
/// Slash commands ("/resume", "!ls") don't describe a session; prefer the
/// first entry that reads like an actual prompt, fall back to anything.
fn session_titles() -> std::collections::HashMap<String, String> {
    #[derive(Deserialize)]
    #[serde(rename_all = "camelCase")]
    struct HistEntry {
        display: String,
        session_id: Option<String>,
    }
    let mut first: std::collections::HashMap<String, String> = Default::default();
    let Ok(text) = std::fs::read_to_string(home().join(".claude/history.jsonl")) else {
        return first;
    };
    for line in text.lines() {
        let Ok(e) = serde_json::from_str::<HistEntry>(line) else {
            continue;
        };
        let Some(sid) = e.session_id else { continue };
        let d = e.display.trim();
        // Command-only entries ("/resume", "!ls") don't describe a session.
        if d.is_empty() || d.starts_with('/') || d.starts_with('!') || d.starts_with('#') {
            continue;
        }
        first.entry(sid).or_insert_with(|| d.to_string());
    }
    // Titles render on one line; don't ship multi-KB pasted prompts.
    for v in first.values_mut() {
        if let Some((i, _)) = v.char_indices().nth(160) {
            v.truncate(i);
            v.push('…');
        }
        *v = v.replace('\n', " ");
    }
    first
}

fn home() -> PathBuf {
    std::env::var_os("HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/tmp"))
}

fn pid_alive(pid: i32) -> bool {
    unsafe { libc::kill(pid, 0) == 0 || *libc::__error() == libc::EPERM }
}

// Minimal proc_bsdinfo (sys/proc_info.h) — gives ppid + kernel start time.
#[repr(C)]
#[derive(Clone, Copy)]
struct ProcBsdInfo {
    pbi_flags: u32,
    pbi_status: u32,
    pbi_xstatus: u32,
    pbi_pid: u32,
    pbi_ppid: u32,
    pbi_uid: u32,
    pbi_gid: u32,
    pbi_ruid: u32,
    pbi_rgid: u32,
    pbi_svuid: u32,
    pbi_svgid: u32,
    rfu_1: u32,
    pbi_comm: [u8; 16],
    pbi_name: [u8; 32],
    pbi_nfiles: u32,
    pbi_pgid: u32,
    pbi_pjobc: u32,
    e_tdev: u32,
    e_tpgid: u32,
    pbi_nice: i32,
    pbi_start_tvsec: u64,
    pbi_start_tvusec: u64,
}

const PROC_PIDTBSDINFO: libc::c_int = 3;

extern "C" {
    fn proc_pidinfo(
        pid: libc::c_int,
        flavor: libc::c_int,
        arg: u64,
        buffer: *mut libc::c_void,
        buffersize: libc::c_int,
    ) -> libc::c_int;
}

fn bsd_info(pid: i32) -> Option<ProcBsdInfo> {
    let mut info: ProcBsdInfo = unsafe { std::mem::zeroed() };
    let size = std::mem::size_of::<ProcBsdInfo>() as libc::c_int;
    let n = unsafe { proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &mut info as *mut _ as *mut libc::c_void, size) };
    if n == size && info.pbi_pid == pid as u32 {
        Some(info)
    } else {
        None
    }
}

/// Kernel process start time (epoch seconds).
fn proc_start_epoch(pid: i32) -> Option<i64> {
    bsd_info(pid).map(|i| i.pbi_start_tvsec as i64)
}

struct ProcRow {
    ppid: i32,
    tty: Option<String>,
    comm: String,
}

/// Snapshot of the full process table via ps (sees root-owned ancestors
/// like `login`, which proc_pidinfo cannot inspect unprivileged).
fn process_table() -> std::collections::HashMap<i32, ProcRow> {
    let mut map = std::collections::HashMap::new();
    let Ok(out) = Command::new("/bin/ps").args(["-axo", "pid=,ppid=,tty=,comm="]).output() else {
        return map;
    };
    for line in String::from_utf8_lossy(&out.stdout).lines() {
        // Columns: pid ppid tty comm — comm may contain spaces, so take
        // the first three tokens positionally and keep the remainder.
        let mut rest = line.trim_start();
        let mut take = || {
            let end = rest.find(char::is_whitespace).unwrap_or(rest.len());
            let tok = &rest[..end];
            rest = rest[end..].trim_start();
            tok
        };
        let (pid, ppid, tty) = (take(), take(), take());
        let (Ok(pid), Ok(ppid)) = (pid.parse(), ppid.parse()) else {
            continue;
        };
        let tty = if tty == "??" { None } else { Some(format!("/dev/{tty}")) };
        map.insert(pid, ProcRow { ppid, tty, comm: rest.to_string() });
    }
    map
}

/// Walk the ancestor chain to decide what UI hosts this claude process.
fn classify_host(pid: i32, table: &std::collections::HashMap<i32, ProcRow>) -> (String, String) {
    let mut cur = pid;
    for _ in 0..12 {
        let Some(row) = table.get(&cur) else { break };
        let path = &row.comm;
        if path.contains("Code Helper (Plugin)") || path.contains("Code - Insiders Helper") {
            return ("vscode".into(), "Visual Studio Code".into());
        }
        if path.contains("Cursor Helper (Plugin)") {
            return ("cursor".into(), "Cursor".into());
        }
        for (needle, label) in [
            ("Terminal.app", "Terminal"),
            ("iTerm.app", "iTerm2"),
            ("Warp.app", "Warp"),
            ("Alacritty", "Alacritty"),
            ("kitty", "kitty"),
            ("WezTerm", "WezTerm"),
            ("Ghostty", "Ghostty"),
        ] {
            if path.contains(needle) {
                return ("terminal".into(), label.into());
            }
        }
        if row.ppid <= 1 {
            break;
        }
        cur = row.ppid;
    }
    ("unknown".into(), String::new())
}

// ---------- focus ----------

fn focus(s: &Session) -> Result<String, String> {
    match s.host.as_str() {
        "vscode" | "cursor" => focus_ide(s),
        "terminal" => focus_terminal(s),
        _ => Err(format!("don't know how to focus host '{}'", s.host)),
    }
}

/// Focus the IDE window for the session's folder, then deep-link the Claude
/// extension to open/focus this exact session tab. URIs route to the
/// focused window, so ordering matters.
fn focus_ide(s: &Session) -> Result<String, String> {
    let (app, scheme) = match s.host.as_str() {
        "cursor" => ("Cursor", "cursor"),
        _ => ("Visual Studio Code", "vscode"),
    };
    run("/usr/bin/open", &["-a", app, &s.cwd])?;
    std::thread::sleep(std::time::Duration::from_millis(500));
    let uri = format!("{scheme}://anthropic.claude-code/open?session={}", s.session_id);
    run("/usr/bin/open", &[&uri])?;
    Ok(format!("ide:{app}"))
}

fn focus_terminal(s: &Session) -> Result<String, String> {
    let Some(tty) = &s.tty else {
        // No tty (shouldn't happen for cli sessions) — at least raise the app.
        run("/usr/bin/open", &["-a", terminal_app_name(&s.host_app)])?;
        return Ok("terminal:activate-only".into());
    };
    let script = match s.host_app.as_str() {
        "iTerm2" => ITERM_FOCUS,
        "Terminal" => TERMINAL_FOCUS,
        _ => {
            run("/usr/bin/open", &["-a", terminal_app_name(&s.host_app)])?;
            return Ok("terminal:activate-only".into());
        }
    };
    let out = Command::new("/usr/bin/osascript")
        .args(["-e", script, tty])
        .output()
        .map_err(|e| e.to_string())?;
    let stdout = String::from_utf8_lossy(&out.stdout).trim().to_string();
    let stderr = String::from_utf8_lossy(&out.stderr).trim().to_string();
    log_line(&format!(
        "osascript {} tty={} exit={:?} stdout={stdout:?} stderr={stderr:?}",
        s.host_app,
        tty,
        out.status.code()
    ));
    if !out.status.success() {
        // -1743: user denied Automation permission; -1719 etc. also land here.
        return Err(if stderr.is_empty() { "osascript failed".into() } else { stderr });
    }
    if stdout == "ok" {
        Ok(format!("terminal:{}", s.host_app))
    } else {
        // Tab not found (closed?) — still bring the app forward.
        run("/usr/bin/open", &["-a", terminal_app_name(&s.host_app)])?;
        Ok("terminal:tab-not-found".into())
    }
}

fn terminal_app_name(label: &str) -> &str {
    match label {
        "iTerm2" => "iTerm",
        "" => "Terminal",
        other => other,
    }
}

fn run(cmd: &str, args: &[&str]) -> Result<(), String> {
    let st = Command::new(cmd)
        .args(args)
        .status()
        .map_err(|e| e.to_string())?;
    if st.success() {
        Ok(())
    } else {
        Err(format!("{cmd} {args:?} exited {st}"))
    }
}

const TERMINAL_FOCUS: &str = r#"
on run argv
    set target to item 1 of argv
    tell application "Terminal"
        repeat with w in windows
            -- Some windows (e.g. Settings) have no tabs; skip them.
            try
                repeat with t in tabs of w
                    if (tty of t) is target then
                        set selected of t to true
                        set index of w to 1
                        activate
                        return "ok"
                    end if
                end repeat
            end try
        end repeat
    end tell
    return "not-found"
end run
"#;

const ITERM_FOCUS: &str = r#"
on run argv
    set target to item 1 of argv
    tell application "iTerm2"
        repeat with w in windows
            try
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        if (tty of s) is target then
                            select w
                            tell w to select t
                            tell t to select s
                            activate
                            return "ok"
                        end if
                    end repeat
                end repeat
            end try
        end repeat
    end tell
    return "not-found"
end run
"#;
