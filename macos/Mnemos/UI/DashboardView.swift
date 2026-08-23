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
            PlaceholderSection(
                title: "Activity",
                subtitle: "Sanitized observations will appear here after capture is implemented.",
                symbol: "clock.arrow.circlepath"
            )
        case .permissions:
            PlaceholderSection(
                title: "Permissions",
                subtitle: "Accessibility onboarding and the application allowlist are the next milestone.",
                symbol: "hand.raised"
            )
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
                    MetricCard(title: "Observations", value: "0", symbol: "text.append")
                    MetricCard(title: "Agent clients", value: "0", symbol: "point.3.connected.trianglepath.dotted")
                }

                VStack(alignment: .leading, spacing: 0) {
                    SectionHeading(title: "Prototype status", subtitle: "Milestone 1 of the local memory system")

                    MilestoneRow(symbol: "checkmark.circle.fill", color: .green, title: "Native macOS shell", detail: "SwiftUI dashboard and menu-bar controls")
                    Divider().padding(.leading, 48)
                    MilestoneRow(symbol: "circle", color: .secondary, title: "Accessibility capture", detail: "Explicit allowlist and privacy filtering")
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
                        Text("Nothing is being recorded yet")
                            .font(.headline)
                        Text("The Start Capture control changes this prototype’s UI state only. We’ll connect it to macOS Accessibility after this shell is verified on your Mac.")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Button(model.isRunning ? "Pause" : "Try UI state") {
                        model.toggleCapture()
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
