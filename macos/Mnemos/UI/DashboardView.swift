import SwiftUI

struct DashboardView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        NavigationSplitView {
            List(SidebarSection.allCases, selection: $model.selectedSection) { section in
                Label(section.rawValue, systemImage: section.symbol)
                    .tag(section)
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 260)
            .safeAreaInset(edge: .bottom) {
                SidebarStatus(status: model.status)
            }
        } detail: {
            detail
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder
    private var detail: some View {
        switch model.selectedSection {
        case .overview:
            OverviewView()
        case .activity:
            ActivityView()
        case .memory:
            MemoryView()
        case .permissions:
            PermissionsView()
        case .agents:
            AgentAccessView()
        case .settings:
            PlaceholderSection(
                title: "Settings",
                subtitle: "Retention, privacy, and launch-at-login controls will live here.",
                symbol: "gearshape"
            )
        }
    }
}

private struct SidebarStatus: View {
    let status: AppModel.CaptureStatus

    var body: some View {
        HStack(spacing: 9) {
            Circle()
                .fill(status == .running ? Color.green : Color.secondary.opacity(0.55))
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(status.rawValue)
                    .font(.caption.weight(.semibold))
                Text("Local only")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}

private struct OverviewView: View {
    @EnvironmentObject private var model: AppModel

    private let columns = [
        GridItem(.flexible(), spacing: 14),
        GridItem(.flexible(), spacing: 14),
        GridItem(.flexible(), spacing: 14),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header

                LazyVGrid(columns: columns, spacing: 14) {
                    MetricCard(title: "Capture", value: model.status.rawValue, symbol: model.status.menuBarSymbol)
                    MetricCard(title: "Stored observations", value: "\(model.memoryHealth.observationCount)", symbol: "text.append")
                    MetricCard(title: "Allowed apps", value: "\(model.allowedBundleIDs.count)", symbol: "checkmark.shield")
                }

                VStack(alignment: .leading, spacing: 0) {
                    SectionHeading(title: "Prototype status", subtitle: "Semantic events and episodes now persist locally across launches")

                    MilestoneRow(symbol: "checkmark.circle.fill", color: .green, title: "Native macOS shell", detail: "SwiftUI dashboard and menu-bar controls")
                    Divider().padding(.leading, 48)
                    MilestoneRow(
                        symbol: model.accessibilityTrusted ? "checkmark.circle.fill" : "circle",
                        color: model.accessibilityTrusted ? .green : .secondary,
                        title: "Semantic event stream",
                        detail: "AX notifications, input targets, tree diffs, and secure-field rejection"
                    )
                    Divider().padding(.leading, 48)
                    MilestoneRow(
                        symbol: model.memoryHealth.label == "Ready" ? "checkmark.circle.fill" : "exclamationmark.circle.fill",
                        color: model.memoryHealth.label == "Ready" ? .green : .orange,
                        title: "Local memory",
                        detail: "SQLite, deterministic episodes, FTS5 retrieval, and evidence drill-down"
                    )
                    Divider().padding(.leading, 48)
                    MilestoneRow(
                        symbol: "circle.lefthalf.filled",
                        color: .blue,
                        title: "Agent access",
                        detail: "Authenticated local API is ready; stdio MCP adapter is next"
                    )
                }
                .cardStyle()

                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "hand.raised.fill")
                        .font(.title3)
                        .foregroundStyle(.blue)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(bannerTitle)
                            .font(.headline)
                        Text(model.captureMessage ?? model.status.detail)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Button(bannerButtonTitle) {
                        if !model.accessibilityTrusted || model.allowedBundleIDs.isEmpty {
                            model.selectedSection = .permissions
                        } else {
                            model.toggleCapture()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(18)
                .background(.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
            }
            .padding(30)
            .frame(maxWidth: 1_100, alignment: .leading)
        }
        .navigationTitle("Overview")
    }

    private var bannerTitle: String {
        if !model.accessibilityTrusted { return "Accessibility access is required" }
        if model.allowedBundleIDs.isEmpty { return "Choose which applications Mnemos may observe" }
        return model.isRunning ? "Live capture is active" : "Ready to capture allowed applications"
    }

    private var bannerButtonTitle: String {
        if !model.accessibilityTrusted { return "Set up" }
        if model.allowedBundleIDs.isEmpty { return "Choose apps" }
        return model.isRunning ? "Pause" : "Start capture"
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Mnemos")
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                Text("A private, user-owned memory layer for local AI agents.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Label("On this Mac", systemImage: "lock.shield.fill")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(.quaternary, in: Capsule())
        }
    }
}

private struct ActivityView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Group {
            if model.events.isEmpty {
                ContentUnavailableView(
                    "No captured activity",
                    systemImage: "clock.arrow.circlepath",
                    description: Text("Grant Accessibility access, allow an application, and start capture. New events also persist in local memory.")
                )
            } else {
                List(model.events) { event in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(event.applicationName)
                                .font(.headline)
                            Text(event.kind.rawValue)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(.quaternary, in: Capsule())
                            Spacer()
                            Text(event.timestamp, format: .dateTime.hour().minute().second())
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        if let title = event.windowTitle {
                            Text(title).lineLimit(2)
                        }
                        if let documentPath = event.documentPath {
                            Label(documentPath, systemImage: "doc")
                                .font(.subheadline.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .textSelection(.enabled)
                        }
                        if let url = event.url {
                            Label(url, systemImage: "globe")
                                .font(.subheadline.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .textSelection(.enabled)
                        }
                        if let target = event.target?.summary {
                            Label(target, systemImage: "scope")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        if let detail = event.detail {
                            Text(detail)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(6)
                                .textSelection(.enabled)
                        }
                        if let axText = event.axText {
                            Text(axText)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(8)
                                .textSelection(.enabled)
                                .padding(8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 7))
                        }
                        Text(event.bundleID)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 6)
                }
            }
        }
        .navigationTitle("Activity")
        .toolbar {
            ToolbarItemGroup {
                Button(model.isRunning ? "Pause" : "Start") { model.toggleCapture() }
                Button("Clear view") { model.clearEvents() }
                    .disabled(model.events.isEmpty)
            }
        }
    }
}

private struct MemoryView: View {
    @EnvironmentObject private var model: AppModel
    @State private var query = ""

    private var isSearching: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var episodes: [MemoryEpisode] {
        isSearching ? model.memorySearchResults.map(\.episode) : model.recentEpisodes
    }

    private var selection: Binding<String?> {
        Binding(
            get: { model.selectedEpisode?.id },
            set: { id in model.selectEpisode(episodes.first(where: { $0.id == id })) }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                TextField("Search projects, windows, URLs, terminal output, or typed context", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { model.searchMemory(query) }
                    .onChange(of: query) { _, newValue in
                        if newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            model.searchMemory("")
                        }
                    }
                Button("Search") { model.searchMemory(query) }
                    .buttonStyle(.borderedProminent)
                    .disabled(!isSearching || model.isMemorySearching)
                Button { model.refreshMemory() } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh memory")
            }
            .padding(16)

            Divider()

            HSplitView {
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(isSearching ? "Search results" : "Recent episodes")
                                .font(.headline)
                            Text(model.memoryHealth.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if model.isMemorySearching {
                            ProgressView().controlSize(.small)
                        }
                    }
                    .padding(14)

                    if let error = model.memoryError {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 14)
                            .padding(.bottom, 10)
                    }

                    if episodes.isEmpty && !model.isMemorySearching {
                        ContentUnavailableView(
                            isSearching ? "No matching memory" : "No episodes yet",
                            systemImage: isSearching ? "magnifyingglass" : "brain.head.profile",
                            description: Text(isSearching ? "Try broader terms." : "Start capture and Mnemos will group observations into episodes.")
                        )
                    } else {
                        List(episodes, selection: selection) { episode in
                            MemoryEpisodeRow(
                                episode: episode,
                                highlights: model.memorySearchResults.first(where: { $0.id == episode.id })?.highlights ?? []
                            )
                            .tag(episode.id)
                        }
                        .listStyle(.inset)
                    }
                }
                .frame(minWidth: 330, idealWidth: 430)

                Group {
                    if let episode = model.selectedEpisode {
                        MemoryEpisodeDetail(episode: episode, evidence: model.selectedEpisodeEvidence)
                    } else {
                        ContentUnavailableView(
                            "Select an episode",
                            systemImage: "doc.text.magnifyingglass",
                            description: Text("Inspect the episode summary and the observations that support it.")
                        )
                    }
                }
                .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("Memory")
        .onAppear { model.refreshMemory() }
    }
}

private struct MemoryEpisodeRow: View {
    let episode: MemoryEpisode
    let highlights: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(episode.title)
                    .font(.headline)
                    .lineLimit(1)
                if episode.isOpen {
                    Text("Live")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.green)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.green.opacity(0.12), in: Capsule())
                }
                Spacer()
                Text(episode.endedAt, format: .dateTime.hour().minute())
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Text(episode.summary)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            if let highlight = highlights.first {
                Text(highlight)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            HStack(spacing: 8) {
                Label("\(episode.eventCount)", systemImage: "text.append")
                if let project = episode.projectKey {
                    Label(project, systemImage: "folder")
                        .lineLimit(1)
                }
            }
            .font(.caption)
            .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 5)
    }
}

private struct MemoryEpisodeDetail: View {
    let episode: MemoryEpisode
    let evidence: [EpisodeEvidence]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 7) {
                    Text(episode.title).font(.title2.weight(.semibold))
                    Text(episode.summary).foregroundStyle(.secondary)
                    Text(episode.startedAt, format: .dateTime.day().month().year().hour().minute())
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }

                if let state = episode.lastState {
                    DetailBlock(title: "Last known state", value: state, symbol: "flag.checkered")
                }
                if !episode.applications.isEmpty {
                    DetailBlock(title: "Applications", value: episode.applications.joined(separator: ", "), symbol: "app.dashed")
                }
                if !episode.artifacts.isEmpty {
                    DetailBlock(title: "Artifacts", value: episode.artifacts.joined(separator: "\n"), symbol: "link")
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("Evidence").font(.headline)
                    if evidence.isEmpty {
                        ProgressView().controlSize(.small)
                    } else {
                        ForEach(evidence) { item in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(item.applicationName).font(.subheadline.weight(.medium))
                                    Text(item.kind).font(.caption).foregroundStyle(.secondary)
                                    Spacer()
                                    Text(item.timestamp, format: .dateTime.hour().minute().second())
                                        .font(.caption2.monospacedDigit())
                                        .foregroundStyle(.tertiary)
                                }
                                if let title = item.windowTitle { Text(title).font(.subheadline).lineLimit(2) }
                                if let detail = item.detail { Text(detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                                if let target = item.target { Text(target).font(.caption2).foregroundStyle(.tertiary) }
                                if let artifact = item.url ?? item.documentPath {
                                    Text(artifact).font(.caption2.monospaced()).foregroundStyle(.tertiary).textSelection(.enabled)
                                }
                            }
                            .padding(10)
                            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }
            }
            .padding(22)
            .frame(maxWidth: 760, alignment: .leading)
        }
    }
}

private struct AgentAccessView: View {
    @EnvironmentObject private var model: AppModel

    private var statusColor: Color {
        switch model.agentAPIStatus {
        case .running: .green
        case .starting: .orange
        case .failed: .red
        case .stopped: .secondary
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 12) {
                        Image(systemName: "point.3.connected.trianglepath.dotted")
                            .font(.title2)
                            .foregroundStyle(.blue)
                            .frame(width: 38, height: 38)
                            .background(.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 9))
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Local agent access").font(.headline)
                            Text("Allow local adapters to retrieve evidence-backed memory while Mnemos is running.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Toggle(
                            "Enable",
                            isOn: Binding(
                                get: { model.agentAccessEnabled },
                                set: { model.setAgentAccessEnabled($0) }
                            )
                        )
                        .labelsHidden()
                    }

                    Divider()

                    HStack(spacing: 9) {
                        Circle().fill(statusColor).frame(width: 9, height: 9)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(model.agentAPIStatus.label).font(.subheadline.weight(.semibold))
                            Text(model.agentAPIStatus.detail).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if model.agentAccessEnabled {
                            Button("Restart") { model.restartAgentAPI() }
                        }
                    }
                }
                .cardStyle()

                VStack(alignment: .leading, spacing: 0) {
                    SectionHeading(
                        title: "Read-only API contract",
                        subtitle: "The upcoming TypeScript stdio MCP adapter will call these endpoints; agents never open SQLite."
                    )
                    Divider()
                    AgentEndpointRow(method: "GET", path: "/v1/health", detail: "Storage health and counts")
                    Divider().padding(.leading, 78)
                    AgentEndpointRow(method: "GET", path: "/v1/episodes/recent", detail: "Recent memory episodes")
                    Divider().padding(.leading, 78)
                    AgentEndpointRow(method: "GET", path: "/v1/search?q=…", detail: "Ranked episode retrieval")
                    Divider().padding(.leading, 78)
                    AgentEndpointRow(method: "GET", path: "/v1/episodes/{id}", detail: "One episode summary")
                    Divider().padding(.leading, 78)
                    AgentEndpointRow(method: "GET", path: "/v1/episodes/{id}/evidence", detail: "Supporting observations")
                }
                .cardStyle()

                VStack(alignment: .leading, spacing: 8) {
                    Label("Connection handoff", systemImage: "key.horizontal.fill")
                        .font(.headline)
                    Text("When enabled, Mnemos rotates a 256-bit bearer token on every launch and writes the endpoint configuration here:")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(model.agentConfigurationPath)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                    Text("The file is readable only by your macOS account. For this prototype, enabling access authorizes every process running as that account—not individual agents. The listener is bound to 127.0.0.1, rejects unauthenticated requests, accepts only GET requests, caps request and result sizes, and sends no browser CORS permission.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .cardStyle()
            }
            .padding(30)
            .frame(maxWidth: 900, alignment: .leading)
        }
        .navigationTitle("Agents")
    }
}

private struct AgentEndpointRow: View {
    let method: String
    let path: String
    let detail: String

    var body: some View {
        HStack(spacing: 12) {
            Text(method)
                .font(.caption.monospaced().weight(.bold))
                .foregroundStyle(.blue)
                .frame(width: 44)
            Text(path).font(.subheadline.monospaced())
            Spacer()
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 11)
    }
}

private struct DetailBlock: View {
    let title: String
    let value: String
    let symbol: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: symbol).font(.headline)
            Text(value)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }
}

private struct PermissionsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var domainDraft = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 12) {
                        Image(systemName: model.accessibilityTrusted ? "checkmark.shield.fill" : "hand.raised.fill")
                            .font(.title2)
                            .foregroundStyle(model.accessibilityTrusted ? .green : .orange)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(model.accessibilityTrusted ? "Accessibility access granted" : "Accessibility access required")
                                .font(.headline)
                            Text("Mnemos uses this permission to read context from applications you explicitly allow.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }

                    HStack {
                        if !model.accessibilityTrusted {
                            Button("Request access") { model.requestAccessibilityPermission() }
                                .buttonStyle(.borderedProminent)
                        }
                        Button("Open System Settings") { model.openAccessibilitySettings() }
                    }
                }
                .cardStyle()

                VStack(alignment: .leading, spacing: 0) {
                    SectionHeading(
                        title: "Allowed applications",
                        subtitle: "The default is none. Browser events additionally require an allowed domain."
                    )
                    Divider()

                    if model.availableApplications.isEmpty {
                        Text("No foreground applications are currently available.")
                            .foregroundStyle(.secondary)
                            .padding(18)
                    } else {
                        ForEach(model.availableApplications) { application in
                            HStack(spacing: 12) {
                                Image(systemName: application.isBrowser ? "globe" : "app")
                                    .frame(width: 24)
                                    .foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(application.name)
                                    Text(application.isBrowser ? "Only allowed domains; private windows are always excluded" : application.bundleID)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Toggle(
                                    "Allow",
                                    isOn: Binding(
                                        get: { model.allowedBundleIDs.contains(application.bundleID) },
                                        set: { model.setApplication(application, allowed: $0) }
                                    )
                                )
                                .labelsHidden()
                            }
                            .padding(.horizontal, 18)
                            .padding(.vertical, 11)
                            Divider().padding(.leading, 54)
                        }
                    }
                }
                .cardStyle()

                VStack(alignment: .leading, spacing: 0) {
                    SectionHeading(
                        title: "Allowed website domains",
                        subtitle: "Browser activity is suppressed unless its current URL matches one of these domains or a subdomain."
                    )
                    Divider()
                    HStack {
                        TextField("github.com", text: $domainDraft)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { addDomain() }
                        Button("Add domain") { addDomain() }
                            .buttonStyle(.borderedProminent)
                            .disabled(domainDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    .padding(18)

                    if !model.allowedDomains.isEmpty {
                        Divider()
                        ForEach(model.allowedDomains.sorted(), id: \.self) { domain in
                            HStack {
                                Label(domain, systemImage: "globe")
                                    .textSelection(.enabled)
                                Spacer()
                                Button("Remove", role: .destructive) {
                                    model.removeAllowedDomain(domain)
                                }
                            }
                            .padding(.horizontal, 18)
                            .padding(.vertical, 10)
                        }
                    }
                }
                .cardStyle()

                Text("Prototype boundary: Mnemos records semantic keyboard text and shortcuts, mouse targets, focused controls, bounded Accessibility-tree snapshots/diffs, selected text, window/document context, terminal changes, and allowed browser URLs/content. Secure input, password controls, private browser windows, disallowed apps/domains, clipboard contents, screenshots, audio, and OCR are excluded. Common credential patterns are redacted. Allowed events persist locally with 30-day raw-observation retention; derived episodes remain available for retrieval.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(30)
            .frame(maxWidth: 900, alignment: .leading)
        }
        .navigationTitle("Permissions")
        .onAppear { model.refreshAvailableApplications() }
    }

    private func addDomain() {
        if model.addAllowedDomain(domainDraft) {
            domainDraft = ""
        }
    }
}

private struct MetricCard: View {
    let title: String
    let value: String
    let symbol: String

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(.blue)
                .frame(width: 32, height: 32)
                .background(.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 3) {
                Text(value)
                    .font(.title2.weight(.semibold))
                Text(title)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }
}

private struct SectionHeading: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.headline)
            Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
        }
        .padding(18)
    }
}

private struct MilestoneRow: View {
    let symbol: String
    let color: Color
    let title: String
    let detail: String

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .foregroundStyle(color)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }
}

private struct PlaceholderSection: View {
    let title: String
    let subtitle: String
    let symbol: String

    var body: some View {
        ContentUnavailableView(title, systemImage: symbol, description: Text(subtitle))
            .navigationTitle(title)
    }
}

private extension View {
    func cardStyle() -> some View {
        padding(18)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .stroke(Color.primary.opacity(0.07), lineWidth: 1)
            }
    }
}
