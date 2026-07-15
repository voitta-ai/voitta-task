import Foundation

struct Session: Decodable, Identifiable, Equatable {
    let pid: Int32
    let sessionId: String
    let name: String
    let cwd: String
    let host: String      // "vscode" | "cursor" | "terminal" | "unknown"
    let hostApp: String   // "Visual Studio Code", "Terminal", "iTerm2", ...
    let kind: String
    let status: String
    let version: String
    let startedAt: Int64  // ms epoch
    let updatedAt: Int64
    let tty: String?
    let title: String?

    var id: Int32 { pid }

    var folder: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return cwd.hasPrefix(home) ? "~" + cwd.dropFirst(home.count) : cwd
    }

    var hostLabel: String {
        switch host {
        case "vscode": return "VS Code"
        case "cursor": return "Cursor"
        case "terminal": return hostApp.isEmpty ? "Terminal" : hostApp
        default: return "?"
        }
    }

    var hostSymbol: String {
        switch host {
        case "vscode", "cursor": return "chevron.left.forwardslash.chevron.right"
        case "terminal": return "terminal"
        default: return "questionmark.circle"
        }
    }

    var updatedAgo: String {
        let secs = max(0, Int(Date().timeIntervalSince1970) - Int(updatedAt / 1000))
        switch secs {
        case ..<60: return "\(secs)s"
        case ..<3600: return "\(secs / 60)m"
        case ..<86400: return "\(secs / 3600)h"
        default: return "\(secs / 86400)d"
        }
    }
}

enum Engine {
    /// The Rust engine ships next to the app executable inside the bundle;
    /// fall back to the dev build path when running via `swift run`.
    static var binaryURL: URL {
        let beside = Bundle.main.executableURL!
            .deletingLastPathComponent()
            .appendingPathComponent("claudebar-engine")
        if FileManager.default.isExecutableFile(atPath: beside.path) { return beside }
        return URL(fileURLWithPath: #filePath) // Sources/ClaudeBar/Engine.swift
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("engine/target/release/claudebar-engine")
    }

    private static func run(_ args: [String]) throws -> Data {
        let p = Process()
        p.executableURL = binaryURL
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return data
    }

    static func list() -> [Session] {
        guard let data = try? run(["list"]),
              let sessions = try? JSONDecoder().decode([Session].self, from: data)
        else { return [] }
        return sessions
    }

    struct ActionResult: Decodable {
        let ok: Bool
        let error: String?
    }

    /// Trigger the one-time Automation permission prompt for a terminal app.
    static func preflight(app: String) {
        DispatchQueue.global(qos: .utility).async {
            _ = try? run(["preflight", app])
        }
    }

    static func focus(pid: Int32, onError: @escaping (String) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            guard let data = try? run(["focus", String(pid)]) else {
                DispatchQueue.main.async { onError("could not run claudebar-engine") }
                return
            }
            if let r = try? JSONDecoder().decode(ActionResult.self, from: data), !r.ok {
                DispatchQueue.main.async { onError(r.error ?? "unknown error") }
            }
        }
    }
}
