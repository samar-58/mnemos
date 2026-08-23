import AppKit
import SwiftUI

@main
struct MnemosApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("Mnemos", id: "dashboard") {
            DashboardView()
                .environmentObject(model)
                .frame(minWidth: 920, minHeight: 620)
        }
        .defaultSize(width: 1_080, height: 720)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        MenuBarExtra {
            MenuBarView()
                .environmentObject(model)
        } label: {
            Label("Mnemos", systemImage: model.status.menuBarSymbol)
        }
        .menuBarExtraStyle(.menu)
    }
}
