import AppKit
import Foundation

@MainActor
final class AppModel: ObservableObject {
    enum CaptureStatus: String {
        case ready = "Ready"
        case running = "Recording"
        case paused = "Paused"

        var menuBarSymbol: String {
            switch self {
            case .ready: "clock.arrow.circlepath"
            case .running: "circle.fill"
            case .paused: "pause.circle.fill"
            }
        }

        var detail: String {
            switch self {
            case .ready: "The app is running. Capture will be connected in the next milestone."
            case .running: "Prototype UI state only—no computer activity is being stored yet."
            case .paused: "Prototype capture is paused."
            }
        }
    }

    @Published var status: CaptureStatus = .ready
    @Published var selectedSection: SidebarSection = .overview

    let launchedAt = Date.now

    var isRunning: Bool { status == .running }

    func toggleCapture() {
        status = status == .running ? .paused : .running
    }

    func showDashboard() {
        NSApp.activate(ignoringOtherApps: true)
        for window in NSApp.windows where window.canBecomeKey {
            window.makeKeyAndOrderFront(nil)
            return
        }
    }

    func quit() {
        NSApp.terminate(nil)
    }
}

enum SidebarSection: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case activity = "Activity"
    case permissions = "Permissions"
    case agents = "Agents"
    case settings = "Settings"

    var id: Self { self }

    var symbol: String {
        switch self {
        case .overview: "rectangle.grid.2x2"
        case .activity: "clock.arrow.circlepath"
        case .permissions: "hand.raised"
        case .agents: "point.3.connected.trianglepath.dotted"
        case .settings: "gearshape"
        }
    }
}

