import SwiftUI

enum SettingsTab: String, CaseIterable, Identifiable {
    case general
    case capture
    case privacy
    case intelligence
    case agents
    case advanced

    var id: Self { self }

    var title: String {
        switch self {
        case .general: "General"
        case .capture: "Capture"
        case .privacy: "Privacy"
        case .intelligence: "Intelligence"
        case .agents: "Agents"
        case .advanced: "Advanced"
        }
    }

    var glyph: String {
        switch self {
        case .general: Glyph.general
        case .capture: Glyph.capture
        case .privacy: Glyph.privacy
        case .intelligence: Glyph.intelligence
        case .agents: Glyph.agents
        case .advanced: Glyph.advanced
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        TabView(selection: $model.settingsTab) {
            ForEach(SettingsTab.allCases) { tab in
                content(for: tab)
                    .tabItem { Label(tab.title, systemImage: tab.glyph) }
                    .tag(tab)
            }
        }
        .frame(width: 620, height: 470)
    }

    @ViewBuilder
    private func content(for tab: SettingsTab) -> some View {
        switch tab {
        case .general: GeneralSettingsView()
        case .capture: CaptureSettingsView()
        case .privacy: PrivacySettingsView()
        case .intelligence: IntelligenceSettingsView()
        case .agents: AgentsSettingsView()
        case .advanced: AdvancedSettingsView()
        }
    }
}

/// A dismissible inline note used across the settings tabs for the feedback
/// `AppModel` produces while you change capture policy.
struct CaptureNote: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        if let message = model.captureMessage {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
                Image(systemName: "info.circle")
                    .foregroundStyle(.tint)
                Text(message)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: Spacing.s)
                Button {
                    model.dismissCaptureMessage()
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption2)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Dismiss")
            }
            .padding(Spacing.s)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: Radius.container, style: .continuous))
        }
    }
}
