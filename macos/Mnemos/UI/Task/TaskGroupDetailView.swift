import SwiftUI

/// A whole timeline entry — every episode of one project on one day — read as a
/// single thing.
///
/// This is the view the roll-up exists for. The segmenter cuts a day's work on
/// one repository into however many episodes the idle gaps produced; opening
/// six of them one at a time to reconstruct an afternoon is the problem. Here
/// the afternoon is the object, and the episodes are its parts.
struct TaskGroupDetailView: View {
    let entry: TimelineGroup
    @EnvironmentObject private var browser: MemoryBrowser
    @AppStorage("showsEvidenceInspector") private var showsInspector = false
    @State private var expandedTaskIDs: Set<String> = []

    private var title: String {
        Narrative.project(for: entry.lead) ?? Narrative.title(for: entry.lead)
    }

    /// Files and links from every episode, collapsed to one entry per name.
    private var artifacts: [(id: String, label: String, detail: String)] {
        var seen = Set<String>()
        var items: [(id: String, label: String, detail: String)] = []
        for task in entry.tasks {
            for item in Narrative.artifacts(for: task) where seen.insert(item.label.lowercased()).inserted {
                items.append(item)
                if items.count == 16 { return items }
            }
        }
        return items
    }

    /// What the whole stretch amounted to, assembled from the episodes rather
    /// than copied from whichever one happened to be first.
    private var summary: String {
        let applications = entry.applications.prefix(3).joined(separator: ", ")
        let count = entry.tasks.count
        var text = "\(count) sessions on \(title)"
        if !applications.isEmpty { text += " in \(applications)" }
        text += ", totalling \(Elapsed.label(seconds: entry.activeSeconds))"
        text += " between \(entry.startedAt.formatted(date: .omitted, time: .shortened))"
        text += " and \(entry.endedAt.formatted(date: .omitted, time: .shortened))."
        return text
    }

    private var lastPlace: String? {
        entry.tasks.compactMap { Narrative.lastPlace(for: $0) }.first
    }

    var body: some View {
        List {
            Section {
                header
            }
            .listRowSeparator(.hidden)

            Section {
                DetailCard(title: "What you were doing", symbol: Glyph.task) {
                    VStack(alignment: .leading, spacing: Spacing.m) {
                        Text(summary)
                            .font(TypeScale.prose)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)

                        if let lastPlace {
                            Divider()
                            VStack(alignment: .leading, spacing: Spacing.xs) {
                                Text("WHERE YOU LEFT OFF")
                                    .font(TypeScale.section)
                                    .foregroundStyle(.secondary)
                                    .kerning(0.4)
                                Text(lastPlace)
                                    .font(TypeScale.prose)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }
                .padding(.vertical, Spacing.xs)
            }
            .listRowSeparator(.hidden)

            if !artifacts.isEmpty {
                Section {
                    SectionHeading(title: "Files and links", trailing: "\(artifacts.count)")
                        .listRowSeparator(.hidden)
                    ForEach(artifacts, id: \.id) { item in
                        ArtifactRow(label: item.label, detail: item.detail)
                    }
                }
            }

            Section {
                ForEach(entry.tasks) { task in
                    episode(task)
                }
            } header: {
                SectionHeading(title: "Sessions", trailing: "\(entry.tasks.count)")
            }
        }
        .listStyle(.inset)
        .navigationTitle(title)
        .navigationSubtitle("\(entry.tasks.count) sessions · \(Elapsed.label(seconds: entry.activeSeconds))")
        .safeAreaInset(edge: .bottom, spacing: 0) { footer }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
                Text(title)
                    .font(TypeScale.display)
                    .lineLimit(2)
                Spacer(minLength: Spacing.s)
            }

            HStack(spacing: Spacing.s) {
                if entry.isOpen { LiveBadge() }
                Chip(text: Elapsed.label(seconds: entry.activeSeconds), symbol: Glyph.recent)
                Chip(text: "\(entry.tasks.count) sessions", symbol: Glyph.sessions)
                if let kind = entry.lead.workstream?.kind {
                    Chip(text: kind.label, symbol: kind.glyph)
                }
            }

            Text(entry.applications.joined(separator: " · "))
                .font(TypeScale.meta)
                .foregroundStyle(.tertiary)
                .lineLimit(2)
        }
        .padding(.vertical, Spacing.s)
    }

    /// One episode, collapsed to a line until asked for. Expanding shows the
    /// same collapsed activity steps the single-task view uses.
    @ViewBuilder
    private func episode(_ task: TaskMemory) -> some View {
        let isExpanded = expandedTaskIDs.contains(task.id)
        let steps = ActivityStep.collapse(browser.selectedGroupSpans[task.id] ?? [])

        VStack(alignment: .leading, spacing: Spacing.xs) {
            Button {
                withAnimation(.snappy(duration: 0.18)) {
                    if isExpanded { expandedTaskIDs.remove(task.id) } else { expandedTaskIDs.insert(task.id) }
                }
            } label: {
                HStack(spacing: Spacing.s) {
                    Image(systemName: Glyph.expand)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .frame(width: 12)
                    Text(Narrative.timeRange(for: task))
                        .font(TypeScale.numeric)
                        .foregroundStyle(.secondary)
                    if task.isOpen { LiveBadge() }
                    Spacer(minLength: Spacing.s)
                    Text(steps.isEmpty ? "\(task.eventCount) observations" : "\(steps.count) steps")
                        .font(TypeScale.meta)
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                if steps.isEmpty {
                    Text("Nothing recorded for this session.")
                        .font(TypeScale.meta)
                        .foregroundStyle(.tertiary)
                        .padding(.leading, Spacing.xl)
                } else {
                    ForEach(steps) { step in
                        SpanRow(step: step)
                            .padding(.leading, Spacing.s)
                    }
                }

                Button("Open this session") {
                    browser.selectedTaskIDs = [task.id]
                    browser.selectionDidChange()
                }
                .buttonStyle(.link)
                .font(TypeScale.meta)
                .padding(.leading, Spacing.xl)
                .padding(.top, Spacing.xxs)
            }
        }
        .padding(.vertical, Spacing.xs)
    }

    private var footer: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: Spacing.s) {
                Button("Copy context") {
                    ContextClipboard.copy(tasks: entry.tasks, evidence: browser.selectedTaskEvidence)
                }
                .buttonStyle(.borderedProminent)
                .help("Copy every session in this group as context for an agent")

                Button("Merge into one task") {
                    browser.merge(taskIDs: entry.tasks.map(\.id))
                }
                .help("Combine these sessions permanently, so search and agents see one task")

                Spacer()

                Button(showsInspector ? "Hide what Mnemos saw" : "Show what Mnemos saw") {
                    showsInspector.toggle()
                }
                .buttonStyle(.link)
                .font(TypeScale.meta)
            }
            .padding(.horizontal, Spacing.l)
            .padding(.vertical, Spacing.s + 1)
        }
        .background(.bar)
    }
}
