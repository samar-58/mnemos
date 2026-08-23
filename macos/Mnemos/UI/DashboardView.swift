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
        case .permissions:
            PermissionsView()
        case .agents:
            PlaceholderSection(
                title: "Agents",
                subtitle: "Codex, Claude, and Cursor connections will be added after local storage and retrieval work.",
                symbol: "point.3.connected.trianglepath.dotted"
            )
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
                    MetricCard(title: "Observations", value: "\(model.events.count)", symbol: "text.append")
                    MetricCard(title: "Allowed apps", value: "\(model.allowedBundleIDs.count)", symbol: "checkmark.shield")
                }

                VStack(alignment: .leading, spacing: 0) {
                    SectionHeading(title: "Prototype status", subtitle: "Live events remain in memory and disappear when Mnemos quits")

                    MilestoneRow(symbol: "checkmark.circle.fill", color: .green, title: "Native macOS shell", detail: "SwiftUI dashboard and menu-bar controls")
                    Divider().padding(.leading, 48)
                    MilestoneRow(
                        symbol: model.accessibilityTrusted ? "checkmark.circle.fill" : "circle",
                        color: model.accessibilityTrusted ? .green : .secondary,
                        title: "Accessibility capture",
                        detail: "Explicit application allowlist and secure-field rejection"
                    )
                    Divider().padding(.leading, 48)
                    MilestoneRow(symbol: "circle", color: .secondary, title: "Local memory", detail: "Encrypted SQLite, episodes, and retrieval")
                    Divider().padding(.leading, 48)
                    MilestoneRow(symbol: "circle", color: .secondary, title: "Agent access", detail: "Authenticated API and stdio MCP adapter")
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
                    description: Text("Grant Accessibility access, allow an application, and start capture. Events stay in memory for this prototype.")
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
                        if let detail = event.detail {
                            Text(detail)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(3)
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
                Button("Clear") { model.clearEvents() }
                    .disabled(model.events.isEmpty)
            }
        }
    }
}

private struct PermissionsView: View {
    @EnvironmentObject private var model: AppModel

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
                        subtitle: "The default is none. Browsers stay disabled until domain-level controls are available."
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
                                    Text(application.isBrowser ? "Browser domain rules required" : application.bundleID)
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
                                .disabled(application.isBrowser)
                            }
                            .padding(.horizontal, 18)
                            .padding(.vertical, 11)
                            Divider().padding(.leading, 54)
                        }
                    }
                }
                .cardStyle()

                Text("Prototype boundary: Mnemos reads focused window titles, explicitly selected text, and non-editable control descriptions. It does not read raw keystrokes, text-field values, clipboard contents, screenshots, audio, or browser page content.")
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
