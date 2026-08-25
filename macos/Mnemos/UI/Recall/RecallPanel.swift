import AppKit
import SwiftUI

/// Holds the SwiftUI window actions so AppKit code — the recall panel and the
/// menu bar — can open the main window even when it has been closed.
@MainActor
final class WindowActions {
    static let shared = WindowActions()
    private var openWindow: OpenWindowAction?

    private init() {}

    func register(_ action: OpenWindowAction) {
        openWindow = action
    }

    func openMain() {
        openWindow?(id: MnemosWindow.main)
        NSApp.activate(ignoringOtherApps: true)
    }

    func open(_ id: String) {
        openWindow?(id: id)
        NSApp.activate(ignoringOtherApps: true)
    }
}

enum MnemosWindow {
    static let main = "main"
    static let welcome = "welcome"
    static let activity = "activity"
}

/// A floating panel that can take key focus without the app stealing the
/// foreground first.
private final class RecallWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Owns the recall panel's lifetime and its response to the global shortcut.
@MainActor
final class RecallPanelController {
    static let shared = RecallPanelController()

    private var panel: NSPanel?
    private var model: AppModel?
    private var hotKeyObserver: NSObjectProtocol?

    private init() {}

    func attach(model: AppModel) {
        self.model = model
        guard hotKeyObserver == nil else { return }
        hotKeyObserver = NotificationCenter.default.addObserver(
            forName: .mnemosRecallHotKey,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in RecallPanelController.shared.toggle() }
        }
    }

    func toggle() {
        if panel?.isVisible == true { hide() } else { show() }
    }

    func show() {
        guard let model else { return }
        let panel = panel ?? makePanel(model: model)
        self.panel = panel
        position(panel)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func makePanel(model: AppModel) -> NSPanel {
        let root = RecallView(
            onOpen: { [weak self] taskID in
                self?.hide()
                WindowActions.shared.openMain()
                model.browser.reveal(taskID: taskID)
            },
            onDismiss: { [weak self] in self?.hide() }
        )
        .environmentObject(model)
        .environmentObject(model.browser)

        let controller = NSHostingController(rootView: root)
        let panel = RecallWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 84),
            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentViewController = controller
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = true
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        return panel
    }

    /// Sits where Spotlight sits: horizontally centred, in the upper third.
    private func position(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let frame = screen.visibleFrame
        let size = panel.frame.size
        panel.setFrameOrigin(
            NSPoint(
                x: frame.midX - size.width / 2,
                y: frame.origin.y + frame.height * 0.72 - size.height / 2
            )
        )
    }
}
