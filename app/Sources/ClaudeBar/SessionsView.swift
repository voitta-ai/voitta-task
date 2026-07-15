import SwiftUI

@MainActor
final class SessionsModel: ObservableObject {
    @Published var sessions: [Session] = []
    private var timer: Timer?

    func startPolling() {
        refresh()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func stopPolling() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        DispatchQueue.global(qos: .userInitiated).async {
            let list = Engine.list()
            DispatchQueue.main.async { self.sessions = list }
        }
    }
}

private struct ListHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct SessionsView: View {
    @ObservedObject var model: SessionsModel
    /// Called after a session row is clicked — the host hides our window.
    var onActivate: () -> Void
    @State private var contentHeight: CGFloat = 0

    /// Grow with content, scroll only past ~3/4 of the screen.
    private var listHeight: CGFloat {
        let cap = (NSScreen.main?.visibleFrame.height ?? 900) * 0.75
        return max(60, min(contentHeight, cap))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Claude Code Sessions")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("\(model.sessions.count)")
                    .font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Capsule().fill(Color.secondary.opacity(0.2)))
            }
            .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 8)

            Divider()

            if model.sessions.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "moon.zzz")
                        .font(.system(size: 24))
                        .foregroundStyle(.secondary)
                    Text("No active sessions")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                ScrollView {
                    // Plain VStack (not lazy): row count is small and we
                    // need the true content height for grow-then-scroll.
                    VStack(spacing: 2) {
                        ForEach(model.sessions) { s in
                            SessionRow(session: s) {
                                onActivate()
                                Engine.focus(pid: s.pid) { err in
                                    showFocusError(err, session: s)
                                }
                            }
                        }
                    }
                    .padding(6)
                    .background(GeometryReader { g in
                        Color.clear.preference(key: ListHeightKey.self, value: g.size.height)
                    })
                }
                .onPreferenceChange(ListHeightKey.self) { contentHeight = $0 }
                .frame(height: listHeight)
            }
        }
        .frame(width: 560)
    }
}

@MainActor
func showFocusError(_ message: String, session: Session) {
    let alert = NSAlert()
    alert.messageText = "Couldn't switch to “\(session.name)”"
    let denied = message.contains("-1743") || message.lowercased().contains("not allowed")
    alert.informativeText = denied
        ? "macOS blocked ClaudeBar from controlling \(session.hostApp). Enable ClaudeBar under Automation in System Settings, then try again."
        : message
    alert.alertStyle = .warning
    if denied {
        alert.addButton(withTitle: "Open Automation Settings")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(
                URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!)
        }
    } else {
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}

private struct SessionRow: View {
    let session: Session
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: session.hostSymbol)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(session.host == "terminal" ? Color.green : Color.blue)
                    .frame(width: 22)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        // Claude Code's own session name (from its registry).
                        Text(session.name)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                        if session.status == "idle" {
                            Circle().fill(Color.secondary.opacity(0.5)).frame(width: 6, height: 6)
                        } else {
                            Circle().fill(Color.green).frame(width: 6, height: 6)
                        }
                    }
                    if let title = session.title, !title.isEmpty {
                        Text(title)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Text(session.folder)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }

                Spacer(minLength: 8)

                VStack(alignment: .trailing, spacing: 2) {
                    Text(session.hostLabel)
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(
                            Capsule().fill(
                                (session.host == "terminal" ? Color.green : Color.blue).opacity(0.15)
                            )
                        )
                    Text(session.updatedAgo)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(hovered ? Color.secondary.opacity(0.12) : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help("\(session.sessionId)\npid \(session.pid)" + (session.tty.map { "\ntty \($0)" } ?? ""))
    }
}
