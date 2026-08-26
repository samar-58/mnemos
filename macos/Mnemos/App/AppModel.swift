import AppKit
import Foundation

/// Owns capture, permissions, and agent access. Everything the memory UI
/// browses lives in `browser`.
@MainActor
final class AppModel: ObservableObject {
    enum CaptureStatus: String {
        case ready = "Ready"
        case running = "Recording"
        case paused = "Paused"
        case permissionRequired = "Permission needed"

        var detail: String {
            switch self {
            case .ready: "Choose the apps Mnemos may observe, then start recording."
            case .running: "Mnemos is recording context from the apps you allowed."
            case .paused: "Recording is paused. Nothing is being captured."
            case .permissionRequired: "Mnemos needs Accessibility access before it can record."
            }
        }
    }

    @Published var status: CaptureStatus = .ready
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
    @Published private(set) var dogfoodRiskAccepted: Bool
    @Published private(set) var customRedactionLiterals: [String]
    @Published private(set) var customRedactionRegexes: [String]
    @Published private(set) var agentAccessEnabled: Bool
    @Published private(set) var agentAPIStatus: AgentAPIStatus = .stopped
    @Published private(set) var agentConfigurationPath = ""
    /// Which tab the Settings window should show when it is opened from code.
    @Published var settingsTab: SettingsTab = .general

    let browser: MemoryBrowser
    let launchedAt = Date.now

    private let captureService = AccessibilityCaptureService()
    private let memoryStore: SQLiteMemoryStore
    private let contextStore: ContextEngineStore
    private let agentAPI: LocalMemoryAPI
    private var monitorTask: Task<Void, Never>?
    private var persistenceTask: Task<Void, Never>?
    private var tickCount = 0
    private var persistedSinceRefresh = 0

    private static let allowedApplicationsKey = "allowedApplicationBundleIDs"
    private static let allowedDomainsKey = "allowedURLDomains"
    private static let agentAccessEnabledKey = "agentAccessEnabled"
    private static let dogfoodRiskAcceptedKey = "dogfoodUnencryptedRiskAccepted"

    init() {
        let memoryStore = SQLiteMemoryStore()
        let contextStore = ContextEngineStore()
        self.memoryStore = memoryStore
        self.contextStore = contextStore
        browser = MemoryBrowser(store: contextStore)
        agentAPI = LocalMemoryAPI(memoryStore: memoryStore, contextStore: contextStore)
        allowedBundleIDs = Set(UserDefaults.standard.stringArray(forKey: Self.allowedApplicationsKey) ?? [])
        allowedDomains = Set(
            (UserDefaults.standard.stringArray(forKey: Self.allowedDomainsKey) ?? [])
                .compactMap(CapturePrivacy.normalizedDomain)
        )
        let environment = ProcessInfo.processInfo.environment
        let isRunningUnitTests = NSClassFromString("XCTestCase") != nil
            || environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestBundlePath"] != nil
            || environment["XCInjectBundleInto"] != nil
        agentAccessEnabled = !isRunningUnitTests
            && UserDefaults.standard.bool(forKey: Self.agentAccessEnabledKey)
        dogfoodRiskAccepted = UserDefaults.standard.bool(forKey: Self.dogfoodRiskAcceptedKey)
        customRedactionLiterals = UserDefaults.standard.stringArray(forKey: CapturePrivacy.customLiteralDefaultsKey) ?? []
        customRedactionRegexes = UserDefaults.standard.stringArray(forKey: CapturePrivacy.customRegexDefaultsKey) ?? []
        refreshAvailableApplications()
        if !accessibilityTrusted { status = .permissionRequired }
        prepareMemoryStores()
        Task { [weak self] in
            guard let self else { return }
            guard !isRunningUnitTests else { return }
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

    /// The task currently being recorded into, if any.
    var openTask: TaskMemory? {
        browser.recentTasks.first(where: \.isOpen)
    }

    var tasksToday: Int {
        let calendar = Calendar.current
        return browser.recentTasks.filter { calendar.isDateInToday($0.endedAt) }.count
    }

    // MARK: - Capture

    func toggleCapture() {
        if status == .running {
            captureService.stop()
            status = .paused
            captureMessage = "Recording paused."
            return
        }

        guard accessibilityTrusted else {
            status = .permissionRequired
            presentSettings(.capture)
            captureMessage = "Grant Accessibility access to continue."
            return
        }

        guard !allowedBundleIDs.isEmpty else {
            status = .ready
            presentSettings(.capture)
            captureMessage = "Choose at least one app for Mnemos to observe."
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
            ? nil
            : "Recording started, but keyboard and mouse context is unavailable on this Mac."
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
            captureMessage = "Add at least one website before allowing a browser."
            return
        }
        if allowed,
           (CapturePrivacy.isTerminal(application.bundleID) || Self.isCommunicationApplication(application)),
           !dogfoodRiskAccepted {
            presentSettings(.advanced)
            captureMessage = "Acknowledge how sensitive apps are stored before allowing terminals or chat apps."
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
            captureMessage = "Enter a website such as github.com."
            return false
        }
        allowedDomains.insert(domain)
        saveAllowedDomains()
        captureService.updatePolicy(allowedBundleIDs: allowedBundleIDs, allowedDomains: allowedDomains)
        captureMessage = nil
        return true
    }

    func removeAllowedDomain(_ domain: String) {
        allowedDomains.remove(domain)
        saveAllowedDomains()
        captureService.updatePolicy(allowedBundleIDs: allowedBundleIDs, allowedDomains: allowedDomains)
        if allowedDomains.isEmpty {
            captureMessage = "Browser activity is ignored until you add a website."
        }
    }

    func clearEvents() {
        events.removeAll()
    }

    func dismissCaptureMessage() {
        captureMessage = nil
    }

    // MARK: - Privacy

    func acceptDogfoodRisk() {
        dogfoodRiskAccepted = true
        UserDefaults.standard.set(true, forKey: Self.dogfoodRiskAcceptedKey)
    }

    @discardableResult
    func addCustomRedactionRule(_ value: String, regex: Bool) -> Bool {
        let rule = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rule.isEmpty else { return false }
        if regex, let error = CapturePrivacy.validateCustomRegex(rule) {
            captureMessage = error
            return false
        }
        let total = customRedactionLiterals.count + customRedactionRegexes.count
        guard total < CapturePrivacy.maximumCustomRules else {
            captureMessage = "Mnemos supports up to \(CapturePrivacy.maximumCustomRules) custom rules."
            return false
        }
        if regex { customRedactionRegexes.append(rule) } else { customRedactionLiterals.append(rule) }
        saveCustomRedactionRules()
        return true
    }

    func removeCustomRedactionRule(_ value: String, regex: Bool) {
        if regex { customRedactionRegexes.removeAll { $0 == value } }
        else { customRedactionLiterals.removeAll { $0 == value } }
        saveCustomRedactionRules()
    }

    func refreshMemory() {
        Task { [weak self] in
            guard let self else { return }
            memoryHealth = await memoryStore.health()
        }
    }

    // MARK: - Agent access

    func setAgentAccessEnabled(_ enabled: Bool) {
        guard enabled != agentAccessEnabled else { return }
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

    // MARK: - Windows

    /// Opens the Settings window on a specific tab.
    func presentSettings(_ tab: SettingsTab) {
        settingsTab = tab
        NSApp.activate(ignoringOtherApps: true)
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }

    func showDashboard() {
        NSApp.activate(ignoringOtherApps: true)
        for window in NSApp.windows where window.canBecomeKey && window.identifier?.rawValue.contains("main") == true {
            window.makeKeyAndOrderFront(nil)
            return
        }
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

    // MARK: - Internals

    /// Both stores share one SQLite file. Preparing the legacy schema first
    /// prevents their startup migrations from racing for the database lock.
    private func prepareMemoryStores() {
        Task { [weak self] in
            guard let self else { return }
            memoryHealth = await memoryStore.health()
            browser.refresh()
        }
    }

    private func tick() {
        let trusted = AccessibilityCaptureService.isTrusted
        if trusted != accessibilityTrusted {
            accessibilityTrusted = trusted
            if trusted {
                status = .ready
                captureMessage = "Accessibility access granted. Choose apps and start recording."
            } else {
                captureService.stop(emitSessionEvent: false)
                status = .permissionRequired
                captureMessage = "Accessibility access was revoked."
            }
        }

        tickCount += 1
        if tickCount.isMultiple(of: 5) { refreshAvailableApplications() }
        refreshAgentAPIStatus()
    }

    private func refreshAgentAPIStatus() {
        Task { [weak self] in
            guard let self else { return }
            let status = await agentAPI.currentStatus()
            let configurationPath = await agentAPI.configurationPath()
            if status != agentAPIStatus { agentAPIStatus = status }
            if configurationPath != agentConfigurationPath {
                agentConfigurationPath = configurationPath
            }
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
                try await contextStore.record(event)
                browser.recordingRecovered()
                persistedSinceRefresh += 1
                if persistedSinceRefresh >= 5 {
                    persistedSinceRefresh = 0
                    memoryHealth = await memoryStore.health()
                    browser.activityDidPersist()
                }
            } catch {
                memoryHealth = MemoryStoreHealth(
                    state: .unavailable(error.localizedDescription),
                    observationCount: memoryHealth.observationCount,
                    episodeCount: memoryHealth.episodeCount
                )
                browser.recordingFailed("Recording stopped updating your memory: \(error.localizedDescription)")
            }
        }
    }

    private func saveAllowedDomains() {
        UserDefaults.standard.set(Array(allowedDomains).sorted(), forKey: Self.allowedDomainsKey)
    }

    private func saveCustomRedactionRules() {
        UserDefaults.standard.set(customRedactionLiterals, forKey: CapturePrivacy.customLiteralDefaultsKey)
        UserDefaults.standard.set(customRedactionRegexes, forKey: CapturePrivacy.customRegexDefaultsKey)
        CapturePrivacy.advanceRedactionPolicyVersion()
        browser.redactionPolicyDidChange()
    }

    private static func isCommunicationApplication(_ application: CapturableApplication) -> Bool {
        let value = "\(application.bundleID) \(application.name)".lowercased()
        return ["whatsapp", "slack", "discord", "messages", "telegram", "signal"].contains(where: value.contains)
    }
}
