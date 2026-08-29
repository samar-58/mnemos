import SwiftUI

/// Menu-bar commands. Every action that used to sit in the Memory toolbar is
/// reachable here, with a shortcut.
struct MnemosCommands: Commands {
    @ObservedObject var model: AppModel
    @AppStorage("showsEvidenceInspector") private var showsInspector = false
    @Environment(\.openWindow) private var openWindow

    private var browser: MemoryBrowser { model.browser }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {}

        CommandGroup(after: .appInfo) {
            Button(model.isRunning ? "Pause Recording" : "Start Recording") {
                model.toggleCapture()
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
        }

        CommandMenu("Memory") {
            Button("Recall…") { RecallPanelController.shared.show() }
                .keyboardShortcut("k")

            Divider()

            Button(browser.selectedTask?.isPinned == true ? "Unpin" : "Pin") {
                browser.togglePin()
            }
            .keyboardShortcut("p", modifiers: [.command, .shift])
            .disabled(browser.selectedTask == nil)

            Button("Rename") {
                browser.renameRequestID = browser.selectedTask?.id
            }
            .keyboardShortcut("r", modifiers: [.command, .option])
            .disabled(browser.selectedTask == nil)

            Divider()

            // Works for a single session and for a whole rolled-up group, so
            // the shortcut copies whatever the detail pane is showing.
            Button("Copy Context") {
                ContextClipboard.copy(tasks: browser.focusedTasks, evidence: browser.selectedTaskEvidence)
            }
            .keyboardShortcut("c", modifiers: [.command, .shift])
            .disabled(browser.focusedTasks.isEmpty)

            Divider()

            Button("Merge Selected Tasks") { browser.mergeSelected() }
                .keyboardShortcut("m", modifiers: [.command, .shift])
                .disabled(browser.focusedTasks.count < 2)

            Button("Split Selected Activity") { browser.splitSelectedSpans() }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(browser.selectedSpanIDs.isEmpty)

            Divider()

            Button("Delete Task…", role: .destructive) {
                browser.pendingDeleteID = browser.selectedTask?.id
            }
            .keyboardShortcut(.delete, modifiers: .command)
            .disabled(browser.selectedTask == nil)

            Divider()

            Button("Refresh") { browser.refresh() }
                .keyboardShortcut("r")
        }

        CommandGroup(after: .sidebar) {
            Button(showsInspector ? "Hide Sources" : "Show What Mnemos Saw") {
                showsInspector.toggle()
            }
            .keyboardShortcut("i", modifiers: [.command, .option])
        }

        CommandGroup(after: .windowList) {
            Button("Live Activity") { openWindow(id: MnemosWindow.activity) }
                .keyboardShortcut("l", modifiers: [.command, .shift])
        }

        CommandGroup(replacing: .help) {
            Link(
                "Mnemos Help",
                destination: URL(string: "https://github.com/samar-58/mnemos#readme")!
            )
        }
    }
}
