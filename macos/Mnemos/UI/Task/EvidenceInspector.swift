import SwiftUI

/// The provenance side of the app: what Mnemos actually saw, grouped by how it
/// was kept.
struct EvidenceInspector: View {
    @EnvironmentObject private var browser: MemoryBrowser

    private var groups: [(source: EvidenceSource, items: [EvidenceItem])] {
        let order: [EvidenceSource] = [.userSelected, .compacted, .raw]
        return order.compactMap { source in
            let items = browser.selectedTaskEvidence.filter { $0.source == source }
            return items.isEmpty ? nil : (source, items)
        }
    }

    var body: some View {
        Group {
            if browser.selectedTask == nil {
                ContentUnavailableView {
                    Label("No task selected", systemImage: Glyph.evidence)
                } description: {
                    Text("Evidence appears here once you select a task.")
                }
            } else if browser.selectedTaskEvidence.isEmpty {
                ContentUnavailableView {
                    Label("No evidence kept", systemImage: Glyph.evidence)
                } description: {
                    Text("Raw activity for this task may have passed its retention window.")
                }
            } else {
                List {
                    ForEach(groups, id: \.source) { group in
                        Section(group.source.label) {
                            ForEach(group.items) { item in
                                EvidenceRow(item: item)
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle("Evidence")
    }
}

private struct EvidenceRow: View {
    let item: EvidenceItem
    @State private var showsProvenance = false

    private var artifact: String? {
        item.url ?? item.documentPath
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(spacing: Spacing.s - 2) {
                Text(item.applicationName)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Chip(text: EventKindLabel.label(for: item.kind))
                Spacer(minLength: Spacing.xs)
                Text(item.timestamp, format: .dateTime.hour().minute())
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            if let excerpt = item.excerpt, !excerpt.isEmpty {
                Text(excerpt)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(6)
                    .textSelection(.enabled)
            }

            if let target = item.target, !target.isEmpty {
                Text(target)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            if let artifact {
                CodeText(text: artifact, lineLimit: 2)
            }

            DisclosureGroup(isExpanded: $showsProvenance) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Kept as \(item.source.label.lowercased())")
                    Text("Redaction rules v\(item.redactionPolicyVersion)")
                    if let observationID = item.observationID {
                        Text(observationID).textSelection(.enabled)
                    }
                }
                .font(.caption2.monospaced())
                .foregroundStyle(.tertiary)
                .padding(.top, 2)
            } label: {
                Text("Where this came from")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, Spacing.xs)
    }
}
