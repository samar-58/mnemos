import SwiftUI

struct AgentsSettingsView: View {
    @EnvironmentObject private var model: AppModel

    private static let endpoints: [(path: String, detail: String)] = [
        ("/v2/health", "Index health and counts"),
        ("/v2/sessions/recent", "Recent tasks, grouped by session"),
        ("/v2/search?q=…", "Filtered task retrieval"),
        ("/v2/context?q=…", "A bounded context pack"),
        ("/v2/tasks/{id}", "One task, its spans, and its neighbours"),
        ("/v2/tasks/{id}/evidence", "Evidence, paginated"),
        ("/v2/timeline", "An explicit time range"),
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
