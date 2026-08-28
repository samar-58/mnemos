import SwiftUI

struct AdvancedSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var browser: MemoryBrowser
    @Environment(\.openWindow) private var openWindow
    @AppStorage(DeveloperDetails.defaultsKey) private var showsDeveloperDetails = false

    var body: some View {
        Form {
            Section {
                Toggle("Show developer details", isOn: $showsDeveloperDetails)
            } header: {
                Text("Developer")
            } footer: {
                Text("Puts event counts, grouping confidence, raw event kinds, file paths, and where each piece of context came from back into the main window. Off by default — the app normally shows what you were doing, not how it was recorded.")
            }

            Section {
                if model.dogfoodRiskAccepted {
                    Label("Acknowledged on this Mac", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    Text("Terminals and chat apps often contain secrets and other people's messages. Because the database is not separately encrypted yet, Mnemos asks you to acknowledge that before recording them.")
                        .foregroundStyle(.secondary)
                    Button("I understand — allow terminals and chat apps") {
                        model.acceptDogfoodRisk()
                    }
                    .buttonStyle(.borderedProminent)
                }
            } header: {
                Text("Sensitive apps")
            }

            Section {
                Button("Rebuild the search index") { browser.rebuildSemanticIndex() }
                    .disabled(!browser.storage.semanticSearchEnabled)
                Button("Open the live activity window") {
                    openWindow(id: MnemosWindow.activity)
                }
            } header: {
                Text("Maintenance")
            } footer: {
                Text("Rebuilding re-reads every task and regenerates its search vectors. The live activity window shows raw events as they are captured, which is useful when checking what Mnemos can see.")
            }

            Section {
                LabeledContent("Memory index") {
                    HStack(spacing: Spacing.s) {
                        StatusDot(tint: browser.health.state == .ready ? .green : .orange)
                        Text(browser.health.detail)
                            .foregroundStyle(.secondary)
                    }
                }
                LabeledContent("Observations") {
                    Text("\(browser.health.observationCount)").monospacedDigit()
                }
                LabeledContent("Search vectors") {
                    Text("\(browser.health.semanticVectorCount)").monospacedDigit()
                }
                LabeledContent("Redaction rules") {
                    Text("Version \(browser.storage.redactionPolicyVersion)").monospacedDigit()
                }
                if case let .unavailable(message) = model.memoryHealth.state {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            } header: {
                Text("Diagnostics")
            }
        }
        .formStyle(.grouped)
        .onAppear { browser.refresh() }
    }
}
