import AppKit
import Foundation

@MainActor
final class AppModel: ObservableObject {
    enum CaptureStatus: String {
        case ready = "Ready"
        case running = "Recording"
        case paused = "Paused"
        case permissionRequired = "Permission needed"

        var menuBarSymbol: String {
            switch self {
            case .ready: "clock.arrow.circlepath"
            case .running: "circle.fill"
            case .paused: "pause.circle.fill"
            case .permissionRequired: "exclamationmark.triangle.fill"
            }
        }

        var detail: String {
            switch self {
            case .ready: "Choose allowed applications, then start capture."
            case .running: "Allowed application context is being captured in memory."
            case .paused: "Capture is paused."
            case .permissionRequired: "Accessibility access is required before capture can start."
            }
        }
    }

    @Published var status: CaptureStatus = .ready
    @Published var selectedSection: SidebarSection = .overview
    @Published private(set) var accessibilityTrusted = AccessibilityCaptureService.isTrusted
    @Published private(set) var availableApplications: [CapturableApplication] = []
    @Published private(set) var allowedBundleIDs: Set<String>
    @Published private(set) var events: [CapturedEvent] = []
    @Published private(set) var captureMessage: String?

    let launchedAt = Date.now
    private let captureService = AccessibilityCaptureService()
    private var monitorTask: Task<Void, Never>?
    private var tickCount = 0

    private static let allowedApplicationsKey = "allowedApplicationBundleIDs"

    init() {
        allowedBundleIDs = Set(UserDefaults.standard.stringArray(forKey: Self.allowedApplicationsKey) ?? [])
        refreshAvailableApplications()
        if !accessibilityTrusted { status = .permissionRequired }

        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.tick()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    var isRunning: Bool { status == .running }

    func toggleCapture() {
        if status == .running {
            status = .paused
            captureMessage = "Capture paused."
            return
        }

        guard accessibilityTrusted else {
            status = .permissionRequired
            selectedSection = .permissions
            captureMessage = "Grant Accessibility access to continue."
            return
        }

        guard !allowedBundleIDs.isEmpty else {
            status = .ready
            selectedSection = .permissions
            captureMessage = "Choose at least one application to capture."
            return
        }

        status = .running
        captureMessage = "Capturing allowed applications in memory."
    }

    func requestAccessibilityPermission() {
        AccessibilityCaptureService.requestPermission()
        captureMessage = "Approve Mnemos in System Settings, then return here."
    }

    func openAccessibilitySettings() {
        AccessibilityCaptureService.openAccessibilitySettings()
    }

    func refreshAvailableApplications() {
        availableApplications = AccessibilityCaptureService.runningApplications(
            excludingBundleID: Bundle.main.bundleIdentifier
        )
    }

    func setApplication(_ application: CapturableApplication, allowed: Bool) {
        guard !application.isBrowser else {
            captureMessage = "Browser capture stays disabled until domain rules are implemented."
            return
        }
        if allowed {
            allowedBundleIDs.insert(application.bundleID)
        } else {
            allowedBundleIDs.remove(application.bundleID)
        }
        UserDefaults.standard.set(Array(allowedBundleIDs).sorted(), forKey: Self.allowedApplicationsKey)
    }

    func clearEvents() {
        events.removeAll()
    }

    private func tick() {
        let trusted = AccessibilityCaptureService.isTrusted
        if trusted != accessibilityTrusted {
            accessibilityTrusted = trusted
            if trusted {
                status = .ready
                captureMessage = "Accessibility access granted. Choose applications and start capture."
            } else {
                status = .permissionRequired
                captureMessage = "Accessibility permission is unavailable."
            }
        }

        tickCount += 1
        if tickCount.isMultiple(of: 5) { refreshAvailableApplications() }

        guard status == .running,
              let event = captureService.captureFrontmostApplication(allowedBundleIDs: allowedBundleIDs) else {
            return
        }
        events.insert(event, at: 0)
        if events.count > 200 { events.removeLast(events.count - 200) }
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
