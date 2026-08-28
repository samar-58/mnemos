import SwiftUI

/// The full record behind one personal skill: what it claims, what supports it,
/// what an agent would literally receive, and every action that changes its
/// trust state. Nothing here is active until the user approves it.
struct SkillDetailView: View {
    let skillID: String
    @EnvironmentObject private var model: AppModel
    @State private var detail: (skill: PersonalSkill, version: SkillVersion, history: [SkillVersion])?
    @State private var showsAgentProjection = false
    @State private var confirmsRetire = false

    var body: some View {
        Group {
            if let detail {
                content(detail)
            } else {
                ContentUnavailableView(
                    "Skill unavailable", systemImage: "wand.and.stars",
                    description: Text("This skill has no approved or candidate version to show.")
                )
            }
        }
        .task(id: skillID) { await reload() }
        .onChange(of: model.personalSkills) { _, _ in Task { await reload() } }
    }

    private func reload() async {
        detail = await model.skillDetail(skillID)
    }

    @ViewBuilder
    private func content(_ detail: (skill: PersonalSkill, version: SkillVersion, history: [SkillVersion])) -> some View {
        let skill = detail.skill
        let version = detail.version
        let activity = model.skillActivity[skill.id] ?? .empty(skillID: skill.id)

        List {
            Section {
                VStack(alignment: .leading, spacing: Spacing.s) {
                    HStack(spacing: Spacing.s) {
                        SkillStatusChip(status: skill.status)
                        Chip(text: "Version \(version.version)")
                        if activity.isExported { Chip(text: "Exported", tint: .blue) }
                    }
                    Text(skill.description)
                        .font(.body)
                        .textSelection(.enabled)
                }
                .listRowSeparator(.hidden)

                actions(skill: skill, activity: activity)
                    .listRowSeparator(.hidden)
            }

            Section("Why Mnemos suggested this") {
                DetailRow("Supported by", value: "\(skill.occurrenceCount) repeated workflows")
                DetailRow("Confidence", value: "\(Int(skill.confidence * 100))%")
                DetailRow("Scope", value: skill.scopeWorkstreamID == nil ? "All projects" : "One project")
                DetailRow("Updated", value: skill.updatedAt.formatted(date: .abbreviated, time: .shortened))
            }

            Section("When it applies") {
                Text(version.trigger.isEmpty ? "No trigger recorded." : version.trigger)
                    .font(.subheadline)
                    .foregroundStyle(version.trigger.isEmpty ? .secondary : .primary)
            }

            listSection("Workflow", items: version.workflow, empty: "No ordered steps recorded.")
            listSection("Preferences", items: version.preferences, empty: "No additional preferences were inferred.")
            listSection("Constraints", items: version.constraints, empty: "No constraints. Mnemos never infers a constraint from absence alone.")
            listSection("Verification", items: version.verification, empty: "No verification habit recorded.")

            Section("Agent use") {
                DetailRow("Times retrieved", value: "\(activity.retrievalCount)")
                DetailRow(
                    "Last retrieved",
                    value: activity.lastRetrievedAt?.formatted(date: .abbreviated, time: .shortened) ?? "Never"
                )
                if let exportedVersion = activity.exportedVersion {
                    DetailRow(
                        "Exported version",
                        value: "Version \(exportedVersion)\(exportedVersion == version.version ? "" : " (out of date)")"
                    )
                }
                Text("Mnemos records only that a skill was retrieved, and when. Agent prompts and replies are never captured.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if detail.history.count > 1 {
                Section("Version history") {
                    ForEach(detail.history) { entry in
                        HStack(spacing: Spacing.m) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Version \(entry.version)").font(.subheadline)
                                Text(entry.approvedAt.map { "Approved \($0.formatted(date: .abbreviated, time: .shortened))" }
                                    ?? "Never approved")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if entry.id == version.id {
                                Chip(text: "Current", tint: .green)
                            } else if entry.approvedAt != nil {
                                Button("Restore") { model.rollbackSkill(skill.id, to: entry.id) }
                                    .controlSize(.small)
                            }
                        }
                    }
                }
            }

            Section {
                DisclosureGroup("What agents receive", isExpanded: $showsAgentProjection) {
                    CodeText(
                        text: NativeSkillExporter.agentFacingMarkdown(skill: skill, version: version),
                        lineLimit: nil
                    )
                    .padding(.vertical, Spacing.xs)
                }
            } footer: {
                Text("This is the exact text a compatible agent would load. It is instructions only: no scripts are ever generated from your commands.")
            }
        }
        .listStyle(.inset)
        .navigationTitle(skill.title)
        .navigationSubtitle(subtitle(for: skill))
        .confirmationDialog(
            "Retire “\(skill.title)”?", isPresented: $confirmsRetire, titleVisibility: .visible
        ) {
            Button("Retire", role: .destructive) { model.retireSkill(skill.id) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Agents stop receiving this skill and any exported package is removed. Its history is kept.")
        }
    }

    @ViewBuilder
    private func actions(skill: PersonalSkill, activity: SkillActivity) -> some View {
        HStack(spacing: Spacing.s) {
            switch skill.status {
            case .candidate:
                Button("Approve") { model.approveSkill(skill.id) }
                    .buttonStyle(.borderedProminent)
                Button("Reject") { model.rejectSkill(skill.id) }
            case .approved:
                Button(activity.isExported ? "Re-export" : "Export Agent Skill") { model.exportSkill(skill.id) }
                    .buttonStyle(.borderedProminent)
                if activity.isExported {
                    Button("Remove export") { model.removeSkillExport(skill.id) }
                }
                Button("Retire", role: .destructive) { confirmsRetire = true }
            case .rejected, .retired:
                Button("Approve again") { model.approveSkill(skill.id) }
            }
            Spacer()
        }
        .controlSize(.regular)
    }

    @ViewBuilder
    private func listSection(_ title: String, items: [String], empty: String) -> some View {
        Section(title) {
            if items.isEmpty {
                Text(empty).font(.subheadline).foregroundStyle(.secondary)
            } else {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    Text(item).font(.subheadline)
                }
            }
        }
    }

    private func subtitle(for skill: PersonalSkill) -> String {
        switch skill.status {
        case .candidate: "Not active until you approve it"
        case .approved: "Trusted working instructions for your agents"
        case .rejected: "Rejected · not suggested again for 90 days"
        case .retired: "Withdrawn from every agent surface"
        }
    }
}
