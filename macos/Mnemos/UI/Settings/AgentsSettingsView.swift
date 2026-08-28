import SwiftUI

struct AgentsSettingsView: View {
    @EnvironmentObject private var model: AppModel

    private static let endpoints: [(path: String, detail: String)] = [
        ("/v3/context/current", "State, memories, and approved skills"),
        ("/v3/memories/search?q=…", "Evidence-backed memory retrieval"),
        ("/v3/tasks/{id}", "Task facts and its derived memory"),
        ("/v3/skills/relevant", "Approved skills only"),
        ("/v3/workstreams/{id}/state", "Decisions and open work"),
        ("/v2/tasks/{id}/evidence", "Explicit provenance escape hatch"),
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

            Section {
                Text(model.agentConfigurationPath.isEmpty ? "Not written yet" : model.agentConfigurationPath)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
            } header: {
                Text("Connection details")
            } footer: {
                Text("Mnemos listens only on this Mac (127.0.0.1) and rotates its access token every launch. The file above is readable only by your account — while access is on, any app running as you can read it, so turn it off when you are not using an agent.")
            }
        }
        .formStyle(.grouped)
    }
}
