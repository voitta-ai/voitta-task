import SwiftUI

@MainActor
final class SessionsModel: ObservableObject {
    @Published var sessions: [Session] = []
    @Published var query = ""
    /// Bumped each time the panel is shown — the view uses it to refocus
    /// (and the model to reset) the search field.
    @Published var showGeneration = 0
    private var timer: Timer?

    /// Case-insensitive substring match against everything user-visible.
    var filtered: [Session] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return sessions }
        return sessions.filter { s in
            [s.name, s.title ?? "", s.folder, s.cwd, s.hostLabel, s.hostApp,
             s.sessionId, s.status, s.tty ?? ""]
                .contains { $0.range(of: q, options: .caseInsensitive) != nil }
        }
    }

    func prepareForShow() {
        query = ""
        showGeneration += 1
    }

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

private struct TotalHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// The Voitta dog (brown dog in a human mask), shown in the panel header.
private let voittaDog: NSImage? = Bundle.module
    .url(forResource: "voitta-dog", withExtension: "png")
    .flatMap { NSImage(contentsOf: $0) }

struct SessionsView: View {
    @ObservedObject var model: SessionsModel
    /// Called after a session row is clicked — the host hides our window.
    var onActivate: () -> Void
    /// Reports the view's natural height so the host window can shrink and
    /// grow with the (possibly filtered) row count.
    var onPreferredHeight: (CGFloat) -> Void = { _ in }
    @State private var contentHeight: CGFloat = 0
    @FocusState private var searchFocused: Bool

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
                Text(model.query.isEmpty
                     ? "\(model.sessions.count)"
                     : "\(model.filtered.count)/\(model.sessions.count)")
                    .font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Capsule().fill(Color.secondary.opacity(0.2)))
                if let dog = voittaDog {
                    Image(nsImage: dog)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .frame(height: 40)
                        .padding(.leading, 4)
                        .accessibilityLabel("Voitta")
                }
                Button {
                    NSApp.terminate(nil)
                } label: {
                    Image(systemName: "power")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .padding(.leading, 2)
                .help("Quit VoittaTask")
            }
            .padding(.horizontal, 14).padding(.top, 8).padding(.bottom, 4)

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                TextField("Filter sessions", text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .focused($searchFocused)
                if !model.query.isEmpty {
                    Button {
                        model.query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.12)))
            .padding(.horizontal, 12).padding(.bottom, 8)
            .onChange(of: model.showGeneration) {
                searchFocused = true
            }

            Divider()

            if model.filtered.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: model.sessions.isEmpty ? "moon.zzz" : "magnifyingglass")
                        .font(.system(size: 24))
                        .foregroundStyle(.secondary)
                    Text(model.sessions.isEmpty ? "No active sessions" : "No matching sessions")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                ScrollView {
                    // Plain VStack (not lazy): row count is small and we
                    // need the true content height for grow-then-scroll.
                    VStack(spacing: 2) {
                        ForEach(model.filtered) { s in
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
        .fixedSize(horizontal: false, vertical: true)
        .background(GeometryReader { g in
            Color.clear.preference(key: TotalHeightKey.self, value: g.size.height)
        })
        .onPreferenceChange(TotalHeightKey.self) { h in
            if h > 0 { onPreferredHeight(h) }
        }
    }
}

@MainActor
func showFocusError(_ message: String, session: Session) {
    let alert = NSAlert()
    alert.messageText = "Couldn't switch to “\(session.name)”"
    let denied = message.contains("-1743") || message.lowercased().contains("not allowed")
    alert.informativeText = denied
        ? "macOS blocked VoittaTask from controlling \(session.hostApp). Enable VoittaTask under Automation in System Settings, then try again."
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

/// Green = agent working; gray = idle; flashing orange = needs attention
/// (turn blocked on a tool call — usually a pending permission approval).
private struct StatusDot: View {
    let state: String
    @State private var dimmed = false

    var body: some View {
        Circle()
            .fill(state == "waiting" ? Color.orange
                  : state == "working" ? Color.green
                  : Color.secondary.opacity(0.5))
            .frame(width: state == "waiting" ? 8 : 6,
                   height: state == "waiting" ? 8 : 6)
            .opacity(dimmed ? 0.15 : 1)
            .onAppear { restartPulse() }
            .onChange(of: state) { restartPulse() }
            .help(state == "waiting" ? "Waiting — likely needs your approval"
                  : state == "working" ? "Working" : "Idle")
    }

    private func restartPulse() {
        if state == "waiting" {
            dimmed = false
            withAnimation(.easeInOut(duration: 0.55).repeatForever(autoreverses: true)) {
                dimmed = true
            }
        } else {
            withAnimation(.linear(duration: 0.1)) { dimmed = false }
        }
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
                        // Human-readable conversation title (first prompt)
                        // leads; the auto-generated registry name is detail.
                        Text(session.displayTitle)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        StatusDot(state: session.state)
                    }
                    if session.hasDistinctName {
                        Text(session.name)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Text(session.folder)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
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
