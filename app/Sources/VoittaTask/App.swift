import SwiftUI

@main
struct VoittaTaskApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        // Status item + dropdown window are managed by AppDelegate.
        Settings { EmptyView() }
    }
}

/// Panel that closes on Escape (cancelOperation walks the responder chain
/// from the SwiftUI content up to the window).
private final class DismissablePanel: NSPanel {
    var onCancel: (() -> Void)?
    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
    // Non-activating panels with .titled style still refuse key status by
    // default heuristics in some configurations; be explicit so ESC works.
    override var canBecomeKey: Bool { true }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var statusItem: NSStatusItem!
    private var window: NSWindow?
    private let model = SessionsModel()
    /// Screen Y of the panel's top edge, set when shown; keeps the panel
    /// hanging from the status item as content growth resizes it.
    private var anchoredTopY: CGFloat?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusItemClicked)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        let img = NSImage(systemSymbolName: "asterisk.circle.fill",
                          accessibilityDescription: "VoittaTask")
        img?.isTemplate = true
        statusItem.button?.image = img

        // Ask for Automation permission up front for every terminal app that
        // currently hosts a session — a launch-time prompt beats a silent
        // failure on first click.
        DispatchQueue.global(qos: .utility).async {
            let terminalApps = Set(
                Engine.list()
                    .filter { $0.host == "terminal" && !$0.hostApp.isEmpty }
                    .map { $0.hostApp == "iTerm2" ? "iTerm" : $0.hostApp }
            )
            for app in terminalApps {
                Engine.preflight(app: app)
            }
        }
    }

    @objc private func statusItemClicked() {
        // Right-click: standard menu-bar-app affordance for Quit.
        if NSApp.currentEvent?.type == .rightMouseUp {
            let menu = NSMenu()
            let quit = NSMenuItem(title: "Quit VoittaTask",
                                  action: #selector(quitApp), keyEquivalent: "q")
            quit.target = self
            menu.addItem(quit)
            // Assign transiently so plain left-clicks keep toggling the panel.
            statusItem.menu = menu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
            return
        }
        toggleWindow()
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    private func toggleWindow() {
        if let w = window, w.isVisible {
            hideWindow()
            return
        }
        showWindow()
    }

    private func showWindow() {
        if window == nil {
            let w = DismissablePanel(
                contentRect: NSRect(x: 0, y: 0, width: 560, height: 460),
                styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
                backing: .buffered, defer: false)
            w.onCancel = { [weak self] in self?.hideWindow() }
            w.titleVisibility = .hidden
            w.titlebarAppearsTransparent = true
            w.isMovableByWindowBackground = true
            w.isReleasedWhenClosed = false
            w.level = .popUpMenu
            // Follow the user to whatever Space they're on, incl. fullscreen.
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            let root = SessionsView(
                model: model,
                onActivate: { [weak self] in self?.hideWindow() },
                onPreferredHeight: { [weak self] h in
                    // Fires during SwiftUI layout — mutate the window after.
                    DispatchQueue.main.async { self?.applyContentHeight(h) }
                })
            let hosting = NSHostingView(rootView: root)
            // The (hidden) titlebar must not inset the content — without
            // this SwiftUI reserves an empty strip at the top of the panel.
            hosting.safeAreaRegions = []
            w.contentView = hosting
            w.delegate = self
            window = w
        }
        model.prepareForShow() // fresh open: clear filter, focus search
        model.startPolling()
        positionNearStatusItem(window!)
        window!.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func hideWindow() {
        model.stopPolling()
        window?.orderOut(nil)
    }

    // Dropdown behavior: clicking anywhere else dismisses the panel.
    func windowDidResignKey(_ notification: Notification) {
        hideWindow()
    }

    /// Resize the panel to the content's natural height (both directions —
    /// filtering can shrink it), keeping the top edge pinned to the anchor.
    private func applyContentHeight(_ contentHeight: CGFloat) {
        guard let w = window else { return }
        // .fullSizeContentView + no safe area: the SwiftUI content covers
        // the whole frame, so frame height == content height exactly.
        let target = contentHeight
        guard abs(w.frame.height - target) > 0.5 else { return }
        var frame = w.frame
        if let top = anchoredTopY {
            frame.origin.y = top - target
        } else {
            frame.origin.y += frame.height - target // keep top edge in place
        }
        frame.size.height = target
        w.setFrame(frame, display: true)
    }

    private func positionNearStatusItem(_ w: NSWindow) {
        guard let btn = statusItem.button, let screen = btn.window?.screen else {
            w.center()
            return
        }
        w.layoutIfNeeded()
        let btnFrame = btn.window?.convertToScreen(btn.frame) ?? .zero
        anchoredTopY = btnFrame.minY - 8
        var origin = NSPoint(x: btnFrame.midX - w.frame.width / 2,
                             y: btnFrame.minY - w.frame.height - 8)
        origin.x = min(max(origin.x, screen.visibleFrame.minX + 8),
                       screen.visibleFrame.maxX - w.frame.width - 8)
        w.setFrameOrigin(origin)
    }
}
