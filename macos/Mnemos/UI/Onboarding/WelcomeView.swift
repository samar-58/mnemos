import SwiftUI

/// First run: what this is, the one permission it needs, and the apps it may
/// watch. Nothing is recorded until the last step.
struct WelcomeView: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage("hasCompletedWelcome") private var hasCompletedWelcome = false
    @Environment(\.dismiss) private var dismiss
    @State private var step = 0

    private var canContinue: Bool {
        switch step {
        case 1: model.accessibilityTrusted
        case 2: !model.allowedBundleIDs.isEmpty
        default: true
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                content
                    .padding(Spacing.xl + Spacing.s)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            footer
        }
        .frame(width: 560, height: 500)
        .onChange(of: model.accessibilityTrusted) { _, trusted in
            if trusted, step == 1 { step = 2 }
        }
        .onAppear { model.refreshAvailableApplications() }
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case 0: intro
        case 1: permission
        default: applications
        }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: Spacing.l) {
            Image("MenuBarIcon")
                .resizable()
                .renderingMode(.template)
                .frame(width: 44, height: 44)
                .foregroundStyle(.tint)

            VStack(alignment: .leading, spacing: Spacing.s) {
                Text("Welcome to Mnemos")
                    .font(.largeTitle.weight(.semibold))
                Text("A memory of your work that you own, and that your AI agents can ask about.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: Spacing.m) {
                WelcomePoint(
                    symbol: "lock.laptopcomputer",
                    title: "Local memory is the default",
                    detail: "Capture and deterministic recall stay on this Mac. Mnemos records no screenshots, audio, or clipboard."
                )
                WelcomePoint(
                    symbol: "accessibility",
                    title: "Accessibility is required for capture",
                    detail: "The app allowlist starts empty, and only the apps you select are observed."
                )
                WelcomePoint(
                    symbol: Glyph.intelligence,
                    title: "Codex enrichment is optional",
                    detail: "Cloud enrichment is off by default and has its own source consent controls. Local recall works without it."
                )
                WelcomePoint(
                    symbol: Glyph.agents,
                    title: "MCP agent access is optional",
                    detail: "Local access is read-only and remains off until you enable it and issue a revocable agent grant."
                )
            }
        }
    }

    private var permission: some View {
        VStack(alignment: .leading, spacing: Spacing.l) {
            stepHeader(
                title: "Allow Accessibility access",
                detail: "This is how Mnemos reads window titles and text from the apps you allow. macOS will ask you to approve it in System Settings."
            )

            HStack(spacing: Spacing.s) {
                StatusDot(tint: model.accessibilityTrusted ? .green : .orange)
                Text(model.accessibilityTrusted ? "Access granted" : "Waiting for approval")
                    .font(.callout)
            }

            if !model.accessibilityTrusted {
                HStack {
                    Button("Request Access") { model.requestAccessibilityPermission() }
                        .buttonStyle(.borderedProminent)
                    Button("Open System Settings") { model.openAccessibilitySettings() }
                }
            }
        }
    }

    private var applications: some View {
        VStack(alignment: .leading, spacing: Spacing.l) {
            stepHeader(
                title: "Choose what Mnemos may observe",
                detail: "Start with one or two apps you work in most. You can change this at any time in Settings."
            )

            if model.availableApplications.isEmpty {
                Text("No apps are running that Mnemos can observe.")
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(model.availableApplications) { application in
                        Toggle(isOn: Binding(
                            get: { model.allowedBundleIDs.contains(application.bundleID) },
                            set: { model.setApplication(application, allowed: $0) }
                        )) {
                            HStack(spacing: Spacing.s) {
                                Image(systemName: application.isBrowser ? Glyph.browser : Glyph.application)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 18)
                                Text(application.name)
                            }
                        }
                        .padding(.vertical, Spacing.xs + 1)
                        Divider()
                    }
                }
            }

            if let message = model.captureMessage {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("After recording starts, optional Codex enrichment lives in Settings → Intelligence, and MCP grants live in Settings → Agents.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func stepHeader(title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Text(title)
                .font(.title2.weight(.semibold))
            Text(detail)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footer: some View {
        HStack {
            ForEach(0..<3) { index in
                Circle()
                    .fill(index == step ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary))
                    .frame(width: 6, height: 6)
            }
            .accessibilityHidden(true)

            Spacer()

            if step > 0 {
                Button("Back") { step -= 1 }
            }

            if step < 2 {
                Button("Continue") { step += 1 }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canContinue)
            } else {
                Button("Start Recording") { finish() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canContinue)
            }
        }
        .padding(Spacing.l)
    }

    private func finish() {
        hasCompletedWelcome = true
        if !model.isRunning { model.toggleCapture() }
        WindowActions.shared.openMain()
        dismiss()
    }
}

private struct WelcomePoint: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.m) {
            Image(systemName: symbol)
                .font(.body)
                .foregroundStyle(.tint)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.headline)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
