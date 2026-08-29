import SwiftUI

/// What Mnemos actually saw, grouped by how it was kept. Hidden until asked
/// for — the rest of the app shows understanding, this shows the raw material.
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
            if browser.focusedTasks.isEmpty {
                ContentUnavailableView {
                    Label("Nothing selected", systemImage: Glyph.evidence)
                } description: {
                    Text("Pick a session to see what Mnemos saw.")
                }
            } else if browser.selectedTaskEvidence.isEmpty {
                ContentUnavailableView {
                    Label("Nothing kept", systemImage: Glyph.evidence)
                } description: {
                    Text("Mnemos no longer keeps the detailed activity for this task.")
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
        .navigationTitle("What Mnemos saw")
    }
}

private struct EvidenceRow: View {
    let item: EvidenceItem
    @AppStorage(DeveloperDetails.defaultsKey) private var showsDeveloperDetails = false
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
                if showsDeveloperDetails {
                    Chip(text: EventKindLabel.label(for: item.kind))
                }
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

            if showsDeveloperDetails {
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
        }
        .padding(.vertical, Spacing.xs)
    }
}
