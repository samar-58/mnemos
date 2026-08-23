import AppKit
import SwiftUI

@main
struct ComputerHistoryApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("Computer History", id: "dashboard") {
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
            Label("Computer History", systemImage: model.status.menuBarSymbol)
        }
        .menuBarExtraStyle(.menu)
    }
}

