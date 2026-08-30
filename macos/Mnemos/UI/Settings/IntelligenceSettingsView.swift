import SwiftUI

struct IntelligenceSettingsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Form {
            Section {
                healthRow("Capture", healthy: model.accessibilityTrusted, value: model.status.rawValue)
                healthRow(
                    "Local memory", healthy: model.memoryHealth.label == "Ready",
                    value: model.memoryHealth.detail
                )
                healthRow("Codex App Server", healthy: model.codexAccountStatus.signedIn,
                          value: model.codexAccountStatus.signedIn ? "Connected" : "Not connected")
                healthRow("Local Mnemos API", healthy: model.agentAPIStatus.isRunning,
                          value: model.agentAPIStatus.label)
                healthRow(
                    "Agent grant",
                    healthy: model.agentGrants.contains { $0.allows(.skills) },
                    value: model.agentGrants.contains { $0.allows(.skills) }
                        ? "Active with skills access" : "No active skills grant"
                )
                healthRow(
                    "MCP activity",
                    healthy: model.agentGrants.contains { $0.lastUsedAt != nil },
                    value: model.agentGrants.compactMap(\.lastUsedAt).max()
                        .map { "Last request \($0.formatted(date: .abbreviated, time: .shortened))" }
                        ?? "No agent request yet"
                )
                LabeledContent("Approved skills", value: "\(model.personalSkills.filter { $0.status == .approved }.count)")
                LabeledContent("Detected patterns", value: "\(model.workflowPatterns.count)")
                if let completed = model.derivationStatus?.lastSuccessfulRunAt {
                    LabeledContent("Last memory run") { Text(completed, style: .relative) }
                }
            } header: {
                Text("End-to-end health")
            } footer: {
                Text("An approved skill is available to any local MCP agent whose active Mnemos grant includes Approved skills. Native skill export is optional.")
            }

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

            if model.cloudEnrichmentEnabled {
                Section {
                    Picker("Extraction model", selection: Binding(
                        get: { model.extractionModel },
                        set: { model.setExtractionModel($0) }
                    )) {
                        Text("Automatic").tag("")
                        ForEach(model.availableCodexModels, id: \.self) { name in
                            Text(name).tag(name)
                        }
                    }
                    .disabled(!model.codexAccountStatus.signedIn)

                    if let quota = model.codexQuota {
                        LabeledContent("Codex quota used", value: "\(Int(quota.usedPercent))%")
                        if let resets = quota.resetsAt {
                            LabeledContent("Quota resets") { Text(resets, style: .relative) }
                        }
                    }

                    Button(model.isLoadingModels ? "Checking…" : "Check models and quota") {
                        Task { await model.loadCodexRuntimeDetails() }
                    }
                    .disabled(!model.codexAccountStatus.signedIn || model.isLoadingModels)
                } header: {
                    Text("Model and quota")
                } footer: {
                    Text("Automatic prefers a fast model for extraction and falls back to the default model when it is unavailable. Jobs defer on their own once any Codex quota bucket passes 80% used.")
                }

                Section {
                    Button("Preview the next packet…") {
                        Task { await model.loadPacketPreview() }
                    }
                } header: {
                    Text("Outbound packet")
                } footer: {
                    Text("Shows exactly what would leave this Mac for the current window, after redaction and cloud-source filtering. Nothing is sent by opening this.")
                }
            }

            if let status = model.derivationStatus {
                Section {
                    LabeledContent("Pending jobs", value: "\(status.pendingJobs)")
                    LabeledContent("Failed jobs", value: "\(status.failedJobs)")
                    if status.lastSynchronizationSkipped > 0 {
                        LabeledContent("Skipped task memories", value: "\(status.lastSynchronizationSkipped)")
                    }
                    LabeledContent("Next extraction") {
                        Text(status.nextExtractionAt, style: .time)
                    }
                    LabeledContent("Next daily consolidation") {
                        Text(status.nextConsolidationAt, style: .time)
                    }
                    Button("Run due jobs now") { model.runDerivationNow() }
                    if status.failedJobs > 0 {
                        Button("Retry failed jobs") { model.retryFailedDerivations() }
                    }
                    if let error = status.lastError {
                        VStack(alignment: .leading, spacing: Spacing.xs) {
                            Text("Last processing error").font(.caption.weight(.semibold))
                            Text(error).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                            if let date = status.lastErrorAt {
                                Text(date, style: .relative).font(.caption2).foregroundStyle(.tertiary)
                            }
                        }
                    }
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
        .task {
            await model.refreshIntelligenceStatus()
            await model.refreshAgentGrants()
            await model.refreshPersonalInsights()
        }
        .sheet(isPresented: Binding(
            get: { model.packetPreview != nil },
            set: { if !$0 { model.clearPacketPreview() } }
        )) {
            PacketPreviewSheet(text: model.packetPreview ?? "") { model.clearPacketPreview() }
        }
    }

    private func healthRow(_ title: String, healthy: Bool, value: String) -> some View {
        LabeledContent(title) {
            HStack(spacing: Spacing.s) {
                StatusDot(tint: healthy ? .green : .secondary)
                Text(value)
            }
        }
    }
}

/// The inspectable preview the privacy model promises: everything in this
/// sheet is what would be sent, and nothing here has been sent.
private struct PacketPreviewSheet: View {
    let text: String
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            Text("Next outbound packet").font(.headline)
            Text("Redacted and filtered to your allowed cloud sources. Reviewing it sends nothing.")
                .font(.caption)
                .foregroundStyle(.secondary)
            ScrollView {
                Text(text)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Spacing.s)
            }
            .frame(minHeight: 320)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: Radius.container, style: .continuous))
            HStack {
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
                Spacer()
                Button("Done", action: onDismiss).keyboardShortcut(.defaultAction)
            }
        }
        .padding(Spacing.xl)
        .frame(width: 620, height: 520)
    }
}
