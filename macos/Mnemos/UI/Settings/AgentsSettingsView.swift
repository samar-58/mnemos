import SwiftUI

struct AgentsSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var isCreatingGrant = false

    private static let endpoints: [(path: String, detail: String)] = [
        ("/v3/context/current", "State, memories, and approved skills"),
        ("/v3/memories/search?q=…", "Evidence-backed memory retrieval"),
        ("/v3/tasks/{id}", "Task facts and its derived memory"),
        ("/v3/skills/relevant", "Approved skills only"),
        ("/v3/workstreams/{id}/state", "Decisions and open work"),
        ("/v2/tasks/{id}/evidence", "Provenance — needs evidence permission"),
    ]

    var body: some View {
        Form {
            Section {
                Toggle(
                    "Let local agents read my memory",
                    isOn: Binding(
                        get: { model.agentAccessEnabled },
                        set: { enabled in
                            Task { @MainActor in
                                await Task.yield()
                                model.setAgentAccessEnabled(enabled)
                            }
                        }
                    )
                )

                LabeledContent {
                    HStack(spacing: Spacing.s) {
                        StatusDot(tint: model.agentAPIStatus.tint)
                        Text(model.agentAPIStatus.label)
                    }
                } label: {
                    Text("Status")
                }

                Text(model.agentAPIStatus.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if model.agentAccessEnabled {
                    Button("Restart") { model.restartAgentAPI() }
                }
            } header: {
                Text("Local agent access")
            } footer: {
                Text("Agents such as Claude, Codex, and Cursor read your memory through the Mnemos adapter while Mnemos is running. Registering the adapter is not enough on its own — this switch is what grants access.")
            }

            Section {
                ForEach(Self.endpoints, id: \.path) { endpoint in
                    HStack(spacing: Spacing.m) {
                        Text("GET")
                            .font(.caption.monospaced().weight(.semibold))
                            .foregroundStyle(.tint)
                            .frame(width: 34, alignment: .leading)
                        Text(endpoint.path)
                            .font(.caption.monospaced())
                        Spacer()
                        Text(endpoint.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("What agents can read")
            } footer: {
                Text("Read-only. Agents cannot change or delete anything, and they never open the database directly.")
            }

            grantsSection

            Section {
                Text(model.agentConfigurationPath.isEmpty ? "Not written yet" : model.agentConfigurationPath)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
            } header: {
                Text("Connection details")
            } footer: {
                Text("Mnemos listens only on this Mac (127.0.0.1) and rotates the built-in grant's token every launch. The file above is readable only by your account — while access is on, any app running as you can read it, so turn it off when you are not using an agent.")
            }
        }
        .formStyle(.grouped)
        .task { await model.refreshAgentGrants() }
        .sheet(isPresented: Binding(
            get: { model.issuedGrantToken != nil },
            set: { if !$0 { model.issuedGrantToken = nil } }
        )) {
            if let issued = model.issuedGrantToken {
                IssuedGrantSheet(
                    name: issued.name, token: issued.token,
                    baseURL: model.agentAPIStatus.baseURL ?? "http://127.0.0.1:17373",
                    processID: ProcessInfo.processInfo.processIdentifier
                ) {
                    model.issuedGrantToken = nil
                }
            }
        }
        .sheet(isPresented: $isCreatingGrant) {
            NewGrantSheet { name, capabilities in
                model.createAgentGrant(name: name, capabilities: capabilities)
                isCreatingGrant = false
            } onCancel: {
                isCreatingGrant = false
            }
        }
    }

    private var grantsSection: some View {
        Section {
            ForEach(model.agentGrants) { grant in
                VStack(alignment: .leading, spacing: Spacing.s) {
                    HStack(spacing: Spacing.s) {
                        Text(grant.displayName).font(.subheadline.weight(.medium))
                        if grant.isDefault { Chip(text: "Built-in") }
                        if !grant.isActive { Chip(text: "Revoked", tint: .orange) }
                        Spacer()
                        grantMenu(for: grant)
                    }

                    ForEach(AgentCapability.allCases, id: \.self) { capability in
                        Toggle(capability.label, isOn: Binding(
                            get: { grant.capabilities.contains(capability) },
                            set: { model.setAgentGrantCapability(grant.id, capability: capability, allowed: $0) }
                        ))
                        .controlSize(.small)
                        .disabled(!grant.isActive)
                    }

                    Text(grant.lastUsedAt.map { "Last used \($0.formatted(date: .abbreviated, time: .shortened))" }
                        ?? "Never used")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, Spacing.xs)
            }

            Button("Create a grant…") { isCreatingGrant = true }
        } header: {
            Text("Agent grants")
        } footer: {
            Text("Each grant is a separate, revocable token. Raw captured evidence is its own permission, so an agent can read derived memories and approved skills without ever seeing the underlying text. Revoking takes effect on the next request.")
        }
    }

    @ViewBuilder
    private func grantMenu(for grant: AgentGrant) -> some View {
        Menu {
            if grant.isActive {
                Button("Revoke", role: .destructive) { model.revokeAgentGrant(grant.id) }
            } else {
                Button("Restore") { model.restoreAgentGrant(grant.id) }
                if !grant.isDefault {
                    Button("Delete", role: .destructive) { model.deleteAgentGrant(grant.id) }
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
}

/// Shown once after a grant is issued. Mnemos keeps only the hash.
private struct IssuedGrantSheet: View {
    let name: String
    let token: String
    let baseURL: String
    let processID: Int32
    let onDismiss: () -> Void

    private var configuration: String {
        """
        {
          "apiVersion": 2,
          "baseURL": "\(baseURL)",
          "bearerToken": "\(token)",
          "processID": \(processID)
        }
        """
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.l) {
            Text("Token for “\(name)”").font(.headline)
            Text("Copy this now. Mnemos stores only a hash, so it cannot show the token again. Save the configuration in a mode-600 file and set MNEMOS_AGENT_CONFIG to its path for this agent's MCP process.")
                .font(.callout)
                .foregroundStyle(.secondary)
            CodeText(text: configuration, lineLimit: nil)
                .padding(Spacing.s)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: Radius.container, style: .continuous))
            HStack {
                Button("Copy configuration") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(configuration, forType: .string)
                }
                Spacer()
                Button("Done", action: onDismiss).keyboardShortcut(.defaultAction)
            }
        }
        .padding(Spacing.xl)
        .frame(width: 560)
    }
}

private extension AgentAPIStatus {
    var baseURL: String? {
        guard case let .running(port) = self else { return nil }
        return "http://127.0.0.1:\(port)"
    }
}

private struct NewGrantSheet: View {
    let onCreate: (String, [AgentCapability]) -> Void
    let onCancel: () -> Void

    @State private var name = ""
    @State private var selected: Set<AgentCapability> = [.memories, .skills]

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.l) {
            Text("New agent grant").font(.headline)
            TextField("Name, such as “Claude Code”", text: $name)
                .textFieldStyle(.roundedBorder)

            VStack(alignment: .leading, spacing: Spacing.xs) {
                ForEach(AgentCapability.allCases, id: \.self) { capability in
                    Toggle(capability.label, isOn: Binding(
                        get: { selected.contains(capability) },
                        set: { if $0 { selected.insert(capability) } else { selected.remove(capability) } }
                    ))
                }
            }

            Text("Grant only what the agent needs. Raw evidence is rarely required for day-to-day work.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Button("Cancel", role: .cancel, action: onCancel)
                Spacer()
                Button("Create") {
                    onCreate(name, AgentCapability.allCases.filter { selected.contains($0) })
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || selected.isEmpty)
            }
        }
        .padding(Spacing.xl)
        .frame(width: 420)
    }
}
