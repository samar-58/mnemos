import SwiftUI

struct CaptureSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var domainDraft = ""

    var body: some View {
        Form {
            if model.captureMessage != nil {
                Section { CaptureNote() }
            }

            Section {
                LabeledContent {
                    HStack(spacing: Spacing.s) {
                        StatusDot(tint: model.accessibilityTrusted ? .green : .orange)
                        Text(model.accessibilityTrusted ? "Granted" : "Not granted")
                    }
                } label: {
                    Text("Accessibility access")
                }

                HStack {
                    if !model.accessibilityTrusted {
                        Button("Request Access") { model.requestAccessibilityPermission() }
                            .buttonStyle(.borderedProminent)
                    }
                    Button("Open System Settings") { model.openAccessibilitySettings() }
                }
            } header: {
                Text("Permission")
            } footer: {
                Text("Mnemos reads window titles, focused controls, and text from the apps you allow below. It never takes screenshots, records audio, or reads your clipboard.")
            }

            Section {
                if model.availableApplications.isEmpty {
                    Text("No apps are running that Mnemos can observe.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.availableApplications) { application in
                        Toggle(isOn: Binding(
                            get: { model.allowedBundleIDs.contains(application.bundleID) },
                            set: { model.setApplication(application, allowed: $0) }
                        )) {
                            HStack(spacing: Spacing.s) {
                                Image(systemName: application.isBrowser ? Glyph.browser : Glyph.application)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 18)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(application.name)
                                    Text(application.isBrowser ? "Allowed websites only · private windows are never recorded" : application.bundleID)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            } header: {
                Text("Apps Mnemos may observe")
            } footer: {
                Text("Nothing is allowed until you say so. Apps appear here while they are running.")
            }

            Section {
                HStack {
                    TextField("github.com", text: $domainDraft)
                        .onSubmit(addDomain)
                    Button("Add", action: addDomain)
                        .disabled(domainDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                ForEach(model.allowedDomains.sorted(), id: \.self) { domain in
                    HStack {
                        Label(domain, systemImage: Glyph.browser)
                            .textSelection(.enabled)
                        Spacer()
                        Button {
                            model.removeAllowedDomain(domain)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("Stop recording \(domain)")
                        .accessibilityLabel("Remove \(domain)")
                    }
                }
            } header: {
                Text("Websites")
            } footer: {
                Text("Browser activity is ignored unless the page matches one of these sites or a subdomain of it.")
            }
        }
        .formStyle(.grouped)
        .onAppear { model.refreshAvailableApplications() }
    }

    private func addDomain() {
        if model.addAllowedDomain(domainDraft) {
            domainDraft = ""
        }
    }
}
