import AppKit
import SwiftUI

@main
struct MnemosApp: App {
    @StateObject private var model = AppModel()
    @AppStorage("hasCompletedWelcome") private var hasCompletedWelcome = false
    @AppStorage(RecallShortcut.defaultsKey) private var shortcutRaw = RecallShortcut.commandOptionSpace.rawValue

    var body: some Scene {
        Window("Mnemos", id: MnemosWindow.main) {
            MainWindowView()
                .environmentObject(model)
                .environmentObject(model.browser)
                .frame(minWidth: 940, minHeight: 600)
                .task { bootstrap() }
        }
        .defaultSize(width: 1_160, height: 760)
        .commands { MnemosCommands(model: model) }

        Window("Welcome to Mnemos", id: MnemosWindow.welcome) {
            WelcomeView()
                .environmentObject(model)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
        .commandsRemoved()

        Window("Live Activity", id: MnemosWindow.activity) {
            LiveActivityWindow()
                .environmentObject(model)
        }
        .defaultSize(width: 940, height: 580)

        Settings {
            SettingsView()
                .environmentObject(model)
                .environmentObject(model.browser)
        }

        MenuBarExtra {
            MenuBarPopover()
                .environmentObject(model)
                .environmentObject(model.browser)
        } label: {
            MenuBarLabel(isRecording: model.isRunning)
        }
        .menuBarExtraStyle(.window)
    }

    @MainActor
    private func bootstrap() {
        RecallPanelController.shared.attach(model: model)
        HotKeyCenter.shared.apply(RecallShortcut(rawValue: shortcutRaw) ?? .commandOptionSpace)
        if !hasCompletedWelcome {
            WindowActions.shared.open(MnemosWindow.welcome)
        }
    }
}

/// The menu bar glyph, with a dot while recording so state is visible without
/// opening the popover.
private struct MenuBarLabel: View {
    let isRecording: Bool

    var body: some View {
        Image("MenuBarIcon")
            .renderingMode(.template)
            .overlay(alignment: .bottomTrailing) {
                if isRecording {
                    Circle()
                        .frame(width: 5, height: 5)
                        .offset(x: 1, y: 1)
                }
            }
            .accessibilityLabel(isRecording ? "Mnemos, recording" : "Mnemos")
    }
}
