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
    @Published private(set) var allowedDomains: Set<String>
    @Published private(set) var events: [CapturedEvent] = []
    @Published private(set) var captureMessage: String?
    @Published private(set) var memoryHealth = MemoryStoreHealth(
        state: .unavailable("Starting local memory…"),
        observationCount: 0,
        episodeCount: 0
    )
    @Published private(set) var recentEpisodes: [MemoryEpisode] = []
    @Published private(set) var memorySearchResults: [MemorySearchResult] = []
    @Published private(set) var selectedEpisode: MemoryEpisode?
    @Published private(set) var selectedEpisodeEvidence: [EpisodeEvidence] = []
    @Published private(set) var memoryError: String?
    @Published private(set) var isMemorySearching = false
    @Published private(set) var agentAccessEnabled: Bool
    @Published private(set) var agentAPIStatus: AgentAPIStatus = .stopped
    @Published private(set) var agentConfigurationPath = ""

    let launchedAt = Date.now
    private let captureService = AccessibilityCaptureService()
    private let memoryStore: SQLiteMemoryStore
    private let agentAPI: LocalMemoryAPI
    private var monitorTask: Task<Void, Never>?
    private var persistenceTask: Task<Void, Never>?
    private var tickCount = 0
    private var persistedSinceRefresh = 0
    private var searchGeneration = 0

    private static let allowedApplicationsKey = "allowedApplicationBundleIDs"
    private static let allowedDomainsKey = "allowedURLDomains"
    private static let agentAccessEnabledKey = "agentAccessEnabled"

    init() {
        let memoryStore = SQLiteMemoryStore()
        self.memoryStore = memoryStore
        agentAPI = LocalMemoryAPI(memoryStore: memoryStore)
        allowedBundleIDs = Set(UserDefaults.standard.stringArray(forKey: Self.allowedApplicationsKey) ?? [])
        allowedDomains = Set(
            (UserDefaults.standard.stringArray(forKey: Self.allowedDomainsKey) ?? [])
                .compactMap(CapturePrivacy.normalizedDomain)
        )
        agentAccessEnabled = UserDefaults.standard.bool(forKey: Self.agentAccessEnabledKey)
        refreshAvailableApplications()
        if !accessibilityTrusted { status = .permissionRequired }
        refreshMemory()
        Task { [weak self] in
            guard let self else { return }
            if agentAccessEnabled {
                await agentAPI.start()
            } else {
                await agentAPI.stop()
            }
            refreshAgentAPIStatus()
        }

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
            captureService.stop()
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
        let inputEventsAvailable = captureService.start(
            allowedBundleIDs: allowedBundleIDs,
            allowedDomains: allowedDomains
        ) { [weak self] event in
            self?.record(event)
        }
        captureMessage = inputEventsAvailable
            ? "Capturing semantic AX, keyboard, mouse, browser, and terminal events in memory."
            : "AX capture is active, but the keyboard/mouse event tap could not start."
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
        guard !application.isBrowser || !allowed || !allowedDomains.isEmpty else {
            captureMessage = "Add at least one allowed website domain before enabling a browser."
            return
        }
        if allowed {
            allowedBundleIDs.insert(application.bundleID)
        } else {
            allowedBundleIDs.remove(application.bundleID)
        }
        UserDefaults.standard.set(Array(allowedBundleIDs).sorted(), forKey: Self.allowedApplicationsKey)
        captureService.updatePolicy(allowedBundleIDs: allowedBundleIDs, allowedDomains: allowedDomains)
    }

    @discardableResult
    func addAllowedDomain(_ value: String) -> Bool {
        guard let domain = CapturePrivacy.normalizedDomain(value) else {
            captureMessage = "Enter a valid domain such as github.com."
            return false
        }
        allowedDomains.insert(domain)
        saveAllowedDomains()
        captureService.updatePolicy(allowedBundleIDs: allowedBundleIDs, allowedDomains: allowedDomains)
        captureMessage = "Allowed browser domain: \(domain)"
        return true
    }

    func removeAllowedDomain(_ domain: String) {
        allowedDomains.remove(domain)
        saveAllowedDomains()
        captureService.updatePolicy(allowedBundleIDs: allowedBundleIDs, allowedDomains: allowedDomains)
        if allowedDomains.isEmpty {
            captureMessage = "Browser events are suppressed until another domain is allowed."
        }
    }

    func clearEvents() {
        events.removeAll()
    }

    func refreshMemory() {
        Task { [weak self] in
            guard let self else { return }
            let health = await memoryStore.health()
            do {
                let episodes = try await memoryStore.recentEpisodes()
                memoryHealth = health
                recentEpisodes = episodes
                memoryError = nil
                if let selectedEpisode,
                   let refreshed = episodes.first(where: { $0.id == selectedEpisode.id }) {
                    self.selectedEpisode = refreshed
                }
            } catch {
                memoryHealth = health
                memoryError = error.localizedDescription
            }
        }
    }

    func searchMemory(_ query: String) {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        searchGeneration += 1
        let generation = searchGeneration

        guard !normalized.isEmpty else {
            memorySearchResults = []
            isMemorySearching = false
            return
        }

        isMemorySearching = true
        Task { [weak self] in
            guard let self else { return }
            do {
                let results = try await memoryStore.search(normalized)
                guard generation == searchGeneration else { return }
                memorySearchResults = results
                memoryError = nil
                isMemorySearching = false
            } catch {
                guard generation == searchGeneration else { return }
                memorySearchResults = []
                memoryError = error.localizedDescription
                isMemorySearching = false
            }
        }
    }

    func selectEpisode(_ episode: MemoryEpisode?) {
        selectedEpisode = episode
        selectedEpisodeEvidence = []
        guard let episode else { return }

        Task { [weak self] in
            guard let self else { return }
            do {
                let evidence = try await memoryStore.evidence(for: episode.id)
                guard selectedEpisode?.id == episode.id else { return }
                selectedEpisodeEvidence = evidence
                memoryError = nil
            } catch {
                guard selectedEpisode?.id == episode.id else { return }
                memoryError = error.localizedDescription
            }
        }
    }

    func setAgentAccessEnabled(_ enabled: Bool) {
        agentAccessEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.agentAccessEnabledKey)
        Task { [weak self] in
            guard let self else { return }
            if enabled {
                await agentAPI.start()
            } else {
                await agentAPI.stop()
            }
            refreshAgentAPIStatus()
        }
    }

    func restartAgentAPI() {
        guard agentAccessEnabled else { return }
        Task { [weak self] in
            guard let self else { return }
            await agentAPI.stop()
            await agentAPI.start()
            refreshAgentAPIStatus()
        }
    }

    private func tick() {
        let trusted = AccessibilityCaptureService.isTrusted
        if trusted != accessibilityTrusted {
            accessibilityTrusted = trusted
            if trusted {
                status = .ready
                captureMessage = "Accessibility access granted. Choose applications and start capture."
            } else {
                captureService.stop(emitSessionEvent: false)
                status = .permissionRequired
                captureMessage = "Accessibility permission is unavailable."
            }
        }

        tickCount += 1
        if tickCount.isMultiple(of: 5) { refreshAvailableApplications() }
        refreshAgentAPIStatus()
    }

    private func refreshAgentAPIStatus() {
        Task { [weak self] in
            guard let self else { return }
            agentAPIStatus = await agentAPI.currentStatus()
            agentConfigurationPath = await agentAPI.configurationPath()
        }
    }

    private func record(_ event: CapturedEvent) {
        events.insert(event, at: 0)
        if events.count > 500 { events.removeLast(events.count - 500) }

        let previous = persistenceTask
        persistenceTask = Task { [weak self] in
            _ = await previous?.value
            guard let self else { return }
            do {
                try await memoryStore.record(event)
                persistedSinceRefresh += 1
                if persistedSinceRefresh >= 5 || selectedSection == .memory {
                    persistedSinceRefresh = 0
                    let health = await memoryStore.health()
                    let episodes = try await memoryStore.recentEpisodes()
                    memoryHealth = health
                    recentEpisodes = episodes
                    memoryError = nil
                }
            } catch {
                memoryError = error.localizedDescription
                memoryHealth = MemoryStoreHealth(
                    state: .unavailable(error.localizedDescription),
                    observationCount: memoryHealth.observationCount,
                    episodeCount: memoryHealth.episodeCount
                )
            }
        }
    }

    private func saveAllowedDomains() {
        UserDefaults.standard.set(Array(allowedDomains).sorted(), forKey: Self.allowedDomainsKey)
    }

    func showDashboard() {
        NSApp.activate(ignoringOtherApps: true)
        for window in NSApp.windows where window.canBecomeKey {
            window.makeKeyAndOrderFront(nil)
            return
        }
    }

    func quit() {
        Task {
            await agentAPI.stop()
            NSApp.terminate(nil)
        }
    }
}

enum SidebarSection: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case activity = "Activity"
    case memory = "Memory"
    case permissions = "Permissions"
    case agents = "Agents"
    case settings = "Settings"

    var id: Self { self }

    var symbol: String {
        switch self {
        case .overview: "rectangle.grid.2x2"
        case .activity: "clock.arrow.circlepath"
        case .memory: "brain.head.profile"
        case .permissions: "hand.raised"
        case .agents: "point.3.connected.trianglepath.dotted"
        case .settings: "gearshape"
        }
    }
}
