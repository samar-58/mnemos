import SwiftUI

/// A shared status chip so a skill's lifecycle reads the same everywhere.
struct SkillStatusChip: View {
    let status: PersonalSkillStatus

    private var tint: Color {
        switch status {
        case .approved: .green
        case .candidate: .orange
        case .rejected, .retired: .secondary
        }
    }

    private var label: String {
        switch status {
        case .candidate: "Needs review"
        case .approved: "Approved"
        case .rejected: "Rejected"
        case .retired: "Retired"
        }
    }

    var body: some View {
        Chip(text: label, tint: tint)
    }
}

/// Why Mnemos believes a workflow repeats, and the work that supports it.
/// Everything shown here is computed locally; a model may only name a pattern
/// that the occurrence count already justifies.
struct PatternDetailView: View {
    let pattern: WorkflowPattern
    @EnvironmentObject private var model: AppModel
    @State private var supporting: [DerivedMemory] = []

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: Spacing.s) {
                    Text(pattern.summary)
                        .font(.body)
                        .textSelection(.enabled)
                    ConfidenceIndicator(
                        confidence: pattern.confidence,
                        reasons: ["\(pattern.occurrenceCount) similar occurrences", "seen across repeated sessions"]
                    )
                }
                .listRowSeparator(.hidden)
            }

            Section("When it starts") {
                Text(pattern.trigger.isEmpty ? "No single trigger stood out yet." : pattern.trigger)
                    .font(.subheadline)
                    .foregroundStyle(pattern.trigger.isEmpty ? .secondary : .primary)
            }

            Section("Steps Mnemos observed") {
                if pattern.workflow.isEmpty {
                    Text("No ordered steps were recorded for this pattern.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(pattern.workflow.enumerated()), id: \.offset) { index, step in
                        HStack(alignment: .firstTextBaseline, spacing: Spacing.m) {
                            Text("\(index + 1)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 18, alignment: .trailing)
                            Text(step).font(.subheadline)
                        }
                    }
                }
            }

            Section("Evidence") {
                DetailRow("Occurrences", value: "\(pattern.occurrenceCount)")
                DetailRow("First seen", value: pattern.firstSeenAt.formatted(date: .abbreviated, time: .shortened))
                DetailRow("Last seen", value: pattern.lastSeenAt.formatted(date: .abbreviated, time: .shortened))
                DetailRow("Scope", value: pattern.scopeWorkstreamID == nil ? "All projects" : "One project")
            }

            Section("Supporting work") {
                if supporting.isEmpty {
                    Text("The tasks behind this pattern are no longer retained.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(supporting) { memory in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(memory.title).font(.subheadline)
                            Text(memory.endedAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .listStyle(.inset)
        .navigationTitle(pattern.title)
        .navigationSubtitle("Detected locally · \(Int(pattern.confidence * 100))% confidence")
        .task(id: pattern.id) {
            supporting = await model.supportingMemories(taskIDs: pattern.evidenceTaskIDs)
        }
    }
}
