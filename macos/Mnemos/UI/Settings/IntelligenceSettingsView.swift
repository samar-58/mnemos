import SwiftUI

struct IntelligenceSettingsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Form {
            Section {
                LabeledContent("Codex") {
                    HStack(spacing: Spacing.s) {
                        StatusDot(tint: model.codexAccountStatus.signedIn ? .green : .secondary)
                        Text(model.codexAccountStatus.signedIn ? "Connected" : "Not connected")
                    }
                }
                if let plan = model.codexAccountStatus.planType {
                    LabeledContent("Plan", value: plan)
                }
                Button(model.codexAccountStatus.signedIn ? "Reconnect Codex" : "Connect Codex") {
                    model.connectCodex()
                }
            } header: {
                Text("Intelligence provider")
            } footer: {
                Text("Mnemos uses a separate Codex sign-in and isolated runtime. It stores no API key, loads no personal plugins or skills, and never gives an enrichment turn access to your files or tools.")
            }

            Section {
                Toggle("Enrich memories with Codex", isOn: Binding(
                    get: { model.cloudEnrichmentEnabled },
                    set: { model.setCloudEnrichmentEnabled($0) }
                ))
                .disabled(!model.codexAccountStatus.signedIn)

                if model.cloudEnrichmentEnabled {
                    ForEach(model.availableApplications.filter { model.allowedBundleIDs.contains($0.bundleID) }) { application in
                        Toggle(application.name, isOn: Binding(
                            get: { model.cloudAllowedBundleIDs.contains(application.bundleID) },
                            set: { model.setCloudApplication(application.bundleID, allowed: $0) }
                        ))
                    }
                    ForEach(model.allowedDomains.sorted(), id: \.self) { domain in
                        Toggle(domain, isOn: Binding(
                            get: { model.cloudAllowedDomains.contains(domain) },
                            set: { model.setCloudDomain(domain, allowed: $0) }
                        ))
                    }
                }
            } header: {
                Text("Sources allowed to leave this Mac")
            } footer: {
                Text("Cloud enrichment is off by default. Local capture permission does not imply cloud permission. Packets are bounded, redacted again, and record partial coverage when a source is omitted.")
            }

            if let status = model.derivationStatus {
                Section {
                    LabeledContent("Pending jobs", value: "\(status.pendingJobs)")
                    LabeledContent("Failed jobs", value: "\(status.failedJobs)")
                    LabeledContent("Next extraction") {
                        Text(status.nextExtractionAt, style: .time)
                    }
                    LabeledContent("Next daily consolidation") {
                        Text(status.nextConsolidationAt, style: .time)
                    }
                    Button("Run due jobs now") { model.runDerivationNow() }
                } header: {
                    Text("Schedule")
                } footer: {
                    Text("Episode extraction runs at 00:00, 06:00, 12:00, and 18:00. Daily consolidation runs at 03:00 after the previous day's extraction is complete.")
                }
            }

            if let message = model.intelligenceMessage {
                Section { Text(message).foregroundStyle(.secondary) }
            }
        }
        .formStyle(.grouped)
        .task { await model.refreshIntelligenceStatus() }
    }
}
