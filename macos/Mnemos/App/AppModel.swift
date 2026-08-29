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
    @Published private(set) var derivationStatus: DerivationStatus?
    @Published private(set) var codexAccountStatus = CodexAccountStatus(signedIn: false, planType: nil)
    @Published private(set) var intelligenceMessage: String?
    @Published private(set) var cloudAllowedBundleIDs: Set<String>
    @Published private(set) var cloudAllowedDomains: Set<String>
    @Published private(set) var workflowPatterns: [WorkflowPattern] = []
    @Published private(set) var personalSkills: [PersonalSkill] = []
    @Published private(set) var skillActivity: [String: SkillActivity] = [:]
    @Published private(set) var agentGrants: [AgentGrant] = []
    @Published private(set) var availableCodexModels: [String] = []
    @Published private(set) var codexQuota: CodexRateLimitStatus?
    @Published private(set) var packetPreview: String?
    @Published private(set) var isLoadingModels = false
    /// Shown once, immediately after a grant is issued. Mnemos stores only the
    /// hash, so this is the single opportunity to copy the token.
    @Published var issuedGrantToken: (name: String, token: String)?
    /// Which tab the Settings window should show when it is opened from code.
    @Published var settingsTab: SettingsTab = .general

    let browser: MemoryBrowser
    let personalContextStore: PersonalContextStore
    let launchedAt = Date.now

    private let captureService = AccessibilityCaptureService()
    private let memoryStore: SQLiteMemoryStore
    private let contextStore: ContextEngineStore
    private let codexProvider: CodexAppServerProvider
    private let derivationCoordinator: DerivationCoordinator
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
        let personalStore = PersonalContextStore()
        let codexProvider = CodexAppServerProvider()
        self.memoryStore = memoryStore
        self.contextStore = contextStore
        self.personalContextStore = personalStore
        self.codexProvider = codexProvider
        self.derivationCoordinator = DerivationCoordinator(store: personalStore, provider: codexProvider)
        browser = MemoryBrowser(store: contextStore)
        agentAPI = LocalMemoryAPI(memoryStore: memoryStore, contextStore: contextStore, personalStore: personalStore)
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
        cloudAllowedBundleIDs = Set(UserDefaults.standard.stringArray(forKey: PersonalContextStore.cloudApplicationDefaultsKey) ?? [])
        cloudAllowedDomains = Set(UserDefaults.standard.stringArray(forKey: PersonalContextStore.cloudDomainDefaultsKey) ?? [])
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
            await refreshIntelligenceStatus()
            await derivationCoordinator.runDueJobs()
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
            cloudAllowedBundleIDs.remove(application.bundleID)
            saveCloudSources()
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
        cloudAllowedDomains.remove(domain)
        saveCloudSources()
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

    // MARK: - Intelligence

    var cloudEnrichmentEnabled: Bool {
        UserDefaults.standard.bool(forKey: PersonalContextStore.cloudEnabledDefaultsKey)
    }

    func setCloudEnrichmentEnabled(_ enabled: Bool) {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await personalContextStore.setCloudEnrichmentEnabled(enabled)
                intelligenceMessage = enabled
                    ? "Cloud enrichment enabled for explicitly allowed sources."
                    : "Cloud enrichment is off. Deterministic local memory remains available."
                await refreshIntelligenceStatus()
            } catch {
                intelligenceMessage = error.localizedDescription
            }
        }
    }

    func setCloudApplication(_ bundleID: String, allowed: Bool) {
        guard allowedBundleIDs.contains(bundleID) else { return }
        if allowed { cloudAllowedBundleIDs.insert(bundleID) }
        else { cloudAllowedBundleIDs.remove(bundleID) }
        saveCloudSources()
    }

    func setCloudDomain(_ domain: String, allowed: Bool) {
        guard allowedDomains.contains(domain) else { return }
        if allowed { cloudAllowedDomains.insert(domain) }
        else { cloudAllowedDomains.remove(domain) }
        saveCloudSources()
    }

    func connectCodex() {
        Task { [weak self] in
            guard let self else { return }
            do {
                let login = try await codexProvider.beginLogin()
                NSWorkspace.shared.open(login.authorizationURL)
                intelligenceMessage = "Finish signing in to Codex in your browser, then return to Mnemos."
            } catch {
                intelligenceMessage = error.localizedDescription
            }
        }
    }

    func refreshIntelligenceStatus() async {
        derivationStatus = try? await personalContextStore.derivationStatus()
        if let account = try? await codexProvider.accountStatus() { codexAccountStatus = account }
    }

    /// Which model runs episode extraction. Empty means "use the built-in
    /// preference order", which is what most people should leave it on.
    var extractionModel: String {
        UserDefaults.standard.string(forKey: PersonalContextStore.extractionModelDefaultsKey) ?? ""
    }

    func setExtractionModel(_ model: String) {
        if model.isEmpty {
            UserDefaults.standard.removeObject(forKey: PersonalContextStore.extractionModelDefaultsKey)
        } else {
            UserDefaults.standard.set(model, forKey: PersonalContextStore.extractionModelDefaultsKey)
        }
        objectWillChange.send()
    }

    /// Both of these start the Codex process, so they are only ever loaded on
    /// demand from the Intelligence tab, never on a timer.
    func loadCodexRuntimeDetails() async {
        guard codexAccountStatus.signedIn, !isLoadingModels else { return }
        isLoadingModels = true
        defer { isLoadingModels = false }
        availableCodexModels = (try? await codexProvider.availableModels()) ?? []
        codexQuota = try? await codexProvider.rateLimitStatus()
    }

    /// Renders exactly what the next enrichment request would contain, after
    /// redaction and cloud-source filtering, so it can be read before it is
    /// ever sent.
    func loadPacketPreview() async {
        let end = Date.now
        let start = PersonalContextStore.previousExtractionBoundary(at: end)
        guard let packet = try? await personalContextStore.evidencePacket(from: start, to: end) else {
            packetPreview = "No tasks in the current window are eligible for enrichment."
            return
        }
        guard !packet.tasks.isEmpty else {
            packetPreview = "No tasks in the current window are eligible for enrichment."
            return
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        packetPreview = (try? encoder.encode(packet)).flatMap { String(data: $0, encoding: .utf8) }
            ?? "The packet could not be rendered."
    }

    func clearPacketPreview() { packetPreview = nil }

    func runDerivationNow() {
        Task { [weak self] in
            guard let self else { return }
            intelligenceMessage = "Processing due memory windows…"
            await derivationCoordinator.runNow()
            await refreshIntelligenceStatus()
            await refreshPersonalInsights()
            intelligenceMessage = "Memory processing is up to date."
        }
    }

    func refreshPersonalInsights() async {
        workflowPatterns = (try? await personalContextStore.patterns(limit: 100)) ?? []
        personalSkills = (try? await personalContextStore.skills(limit: 100)) ?? []
        var activity: [String: SkillActivity] = [:]
        for skill in personalSkills {
            activity[skill.id] = (try? await personalContextStore.skillActivity(skillID: skill.id))
                ?? .empty(skillID: skill.id)
        }
        skillActivity = activity
    }

    // MARK: - Per-agent grants

    func refreshAgentGrants() async {
        agentGrants = (try? await personalContextStore.grants()) ?? []
    }

    func createAgentGrant(name: String, capabilities: [AgentCapability]) {
        Task { [weak self] in
            guard let self else { return }
            do {
                let issued = try await personalContextStore.createGrant(
                    displayName: name, capabilities: capabilities
                )
                issuedGrantToken = (issued.grant.displayName, issued.token)
                await refreshAgentGrants()
            } catch { intelligenceMessage = error.localizedDescription }
        }
    }

    func setAgentGrantCapability(_ id: String, capability: AgentCapability, allowed: Bool) {
        Task { [weak self] in
            guard let self else { return }
            guard let grant = agentGrants.first(where: { $0.id == id }) else { return }
            var capabilities = Set(grant.capabilities)
            if allowed { capabilities.insert(capability) } else { capabilities.remove(capability) }
            do {
                try await personalContextStore.setGrantCapabilities(
                    id: id, capabilities: AgentCapability.allCases.filter { capabilities.contains($0) }
                )
                await refreshAgentGrants()
            } catch { intelligenceMessage = error.localizedDescription }
        }
    }

    func revokeAgentGrant(_ id: String) {
        Task { [weak self] in
            guard let self else { return }
            try? await personalContextStore.revokeGrant(id: id)
            await refreshAgentGrants()
        }
    }

    func restoreAgentGrant(_ id: String) {
        Task { [weak self] in
            guard let self else { return }
            try? await personalContextStore.restoreGrant(id: id)
            await refreshAgentGrants()
        }
    }

    func deleteAgentGrant(_ id: String) {
        Task { [weak self] in
            guard let self else { return }
            try? await personalContextStore.deleteGrant(id: id)
            await refreshAgentGrants()
        }
    }

    /// Resolves the derived memories behind a pattern's occurrences, so a
    /// suggestion can always be traced back to the work that produced it.
    func supportingMemories(taskIDs: [String]) async -> [DerivedMemory] {
        var memories: [DerivedMemory] = []
        for taskID in taskIDs.prefix(12) {
            if let memory = try? await personalContextStore.memory(forTaskID: taskID) {
                memories.append(memory)
            }
        }
        return memories
    }

    /// Loads the full record behind one skill: its current version plus every
    /// earlier version, so the detail view can show history and rollback.
    func skillDetail(_ id: String) async -> (skill: PersonalSkill, version: SkillVersion, history: [SkillVersion])? {
        guard let pair = try? await personalContextStore.skill(id: id) else { return nil }
        let history = (try? await personalContextStore.skillVersions(skillID: id)) ?? []
        return (pair.0, pair.1, history)
    }

    func approveSkill(_ id: String) {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await personalContextStore.approveSkill(id: id)
                await refreshPersonalInsights()
            } catch { intelligenceMessage = error.localizedDescription }
        }
    }

    func rejectSkill(_ id: String) {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await personalContextStore.rejectSkill(id: id)
                await refreshPersonalInsights()
            } catch { intelligenceMessage = error.localizedDescription }
        }
    }

    func exportSkill(_ id: String) {
        Task { [weak self] in
            guard let self else { return }
            do {
                guard let pair = try await personalContextStore.skill(id: id) else {
                    throw NativeSkillExportError.notApproved
                }
                let url = try NativeSkillExporter.export(skill: pair.0, version: pair.1)
                try await personalContextStore.recordSkillExport(
                    skillID: id, versionID: pair.1.id, versionNumber: pair.1.version
                )
                await refreshPersonalInsights()
                intelligenceMessage = "Exported to \(url.path)"
            } catch { intelligenceMessage = error.localizedDescription }
        }
    }

    func removeSkillExport(_ id: String) {
        Task { [weak self] in
            guard let self else { return }
            do {
                guard let pair = try await personalContextStore.skill(id: id) else {
                    throw NativeSkillExportError.notApproved
                }
                let removed = try NativeSkillExporter.removeExport(skill: pair.0)
                try await personalContextStore.recordSkillExportRemoved(skillID: id)
                await refreshPersonalInsights()
                intelligenceMessage = removed
                    ? "Removed the exported skill package."
                    : "No exported package was present; Mnemos cleared its record."
            } catch { intelligenceMessage = error.localizedDescription }
        }
    }

    /// Withdraws an approved skill. Any exported package is removed too, so a
    /// retired skill cannot keep instructing agents from disk.
    func retireSkill(_ id: String) {
        Task { [weak self] in
            guard let self else { return }
            do {
                if let pair = try await personalContextStore.skill(id: id),
                   try NativeSkillExporter.removeExport(skill: pair.0) {
                    try await personalContextStore.recordSkillExportRemoved(skillID: id)
                }
                try await personalContextStore.retireSkill(id: id)
                await refreshPersonalInsights()
                intelligenceMessage = "Retired. Agents no longer receive this skill."
            } catch { intelligenceMessage = error.localizedDescription }
        }
    }

    func rollbackSkill(_ id: String, to versionID: String) {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await personalContextStore.rollbackSkill(id: id, toVersionID: versionID)
                await refreshPersonalInsights()
                intelligenceMessage = "Restored the earlier approved version."
            } catch { intelligenceMessage = error.localizedDescription }
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
            try? await contextStore.prepare()
            try? await personalContextStore.prepare()
            await refreshPersonalInsights()
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
        if tickCount.isMultiple(of: 60) {
            Task { [weak self] in
                guard let self else { return }
                await derivationCoordinator.runDueJobs()
                await refreshIntelligenceStatus()
            }
        }
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
                try await personalContextStore.captureDidPersist()
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

    private func saveCloudSources() {
        let bundles = cloudAllowedBundleIDs.intersection(allowedBundleIDs)
        let domains = cloudAllowedDomains.intersection(allowedDomains)
        cloudAllowedBundleIDs = bundles
        cloudAllowedDomains = domains
        Task { [personalContextStore] in
            await personalContextStore.setCloudSources(bundleIDs: bundles, domains: domains)
        }
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
