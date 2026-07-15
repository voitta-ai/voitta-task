import SwiftUI

@main
struct ClaudeBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        // Status item + dropdown window are managed by AppDelegate.
        Settings { EmptyView() }
    }
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
        statusItem.button?.action = #selector(toggleWindow)
        let img = NSImage(systemSymbolName: "asterisk.circle.fill",
                          accessibilityDescription: "ClaudeBar")
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

    @objc private func toggleWindow() {
        if let w = window, w.isVisible {
            hideWindow()
            return
        }
        showWindow()
    }

    private func showWindow() {
        if window == nil {
            let w = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 560, height: 460),
                styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
                backing: .buffered, defer: false)
            w.titleVisibility = .hidden
            w.titlebarAppearsTransparent = true
            w.isMovableByWindowBackground = true
            w.isReleasedWhenClosed = false
            w.level = .popUpMenu
            // Follow the user to whatever Space they're on, incl. fullscreen.
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            let hosting = NSHostingView(rootView: SessionsView(model: model) { [weak self] in
                self?.hideWindow()
            })
            // Window follows SwiftUI's preferred size (grow-then-scroll).
            hosting.sizingOptions = [.preferredContentSize]
            w.contentView = hosting
            w.delegate = self
            window = w
        }
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

    // Content growth resizes the window; keep its top edge pinned under
    // the status item instead of growing downward off-anchor.
    func windowDidResize(_ notification: Notification) {
        guard let w = window, w.isVisible, let top = anchoredTopY else { return }
        let target = NSPoint(x: w.frame.origin.x, y: top - w.frame.height)
        if abs(target.y - w.frame.origin.y) > 0.5 {
            w.setFrameOrigin(target)
        }
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
