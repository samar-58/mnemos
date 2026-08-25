import SwiftUI

struct GeneralSettingsView: View {
    @AppStorage(RecallShortcut.defaultsKey) private var shortcutRaw = RecallShortcut.commandOptionSpace.rawValue
    @AppStorage("hasCompletedWelcome") private var hasCompletedWelcome = false
    @Environment(\.openWindow) private var openWindow

    private var shortcut: Binding<RecallShortcut> {
        Binding(
            get: { RecallShortcut(rawValue: shortcutRaw) ?? .commandOptionSpace },
            set: { value in
                shortcutRaw = value.rawValue
                HotKeyCenter.shared.apply(value)
            }
        )
    }

    var body: some View {
        Form {
            Section {
                Picker("Recall shortcut", selection: shortcut) {
                    ForEach(RecallShortcut.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                Button("Open recall panel now") {
                    RecallPanelController.shared.show()
                }
                .disabled(shortcut.wrappedValue == .off)
            } header: {
                Text("Quick recall")
            } footer: {
                Text("Search your memory from any app without opening the Mnemos window. Press Return to open a task, ⌘C to copy it as context for an agent.")
            }

            Section {
                Button("Show the welcome guide") {
                    hasCompletedWelcome = false
                    openWindow(id: MnemosWindow.welcome)
                }
            } header: {
                Text("Getting started")
            } footer: {
                Text("Mnemos lives in the menu bar. Closing its window leaves recording running.")
            }
        }
        .formStyle(.grouped)
    }
}
