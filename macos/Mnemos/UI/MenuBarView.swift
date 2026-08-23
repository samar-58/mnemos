import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Open Mnemos") {
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

        Button("Quit Mnemos") {
            model.quit()
        }
        .keyboardShortcut("q")
    }
}
