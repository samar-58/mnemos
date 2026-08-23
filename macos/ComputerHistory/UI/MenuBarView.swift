import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Open Computer History") {
            openWindow(id: "dashboard")
            model.showDashboard()
        }
        .keyboardShortcut("o")

        Divider()

        Button(model.isRunning ? "Pause Capture" : "Start Capture") {
            model.toggleCapture()
        }

        Text("Status: \(model.status.rawValue)")

        Divider()

        Button("Quit Computer History") {
            model.quit()
        }
        .keyboardShortcut("q")
    }
}

