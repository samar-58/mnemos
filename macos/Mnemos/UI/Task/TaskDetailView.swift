import AppKit
import SwiftUI

struct TaskDetailView: View {
    let task: TaskMemory
    @EnvironmentObject private var browser: MemoryBrowser
    @AppStorage(DeveloperDetails.defaultsKey) private var showsDeveloperDetails = false
    @AppStorage("showsEvidenceInspector") private var showsInspector = false
    @State private var titleDraft = ""
    @FocusState private var titleFocused: Bool

    private var steps: [ActivityStep] { browser.selectedTaskSteps }

    private var artifacts: [(id: String, label: String, detail: String)] {
        Narrative.artifacts(for: task)
    }

    var body: some View {
        List(selection: $browser.selectedSpanIDs) {
            Section {
                header
            }
            .selectionDisabled()
            .listRowSeparator(.hidden)

            Section {
                summaryCard
            }
            .selectionDisabled()
            .listRowSeparator(.hidden)

            if !artifacts.isEmpty {
                Section {
                    SectionHeading(title: "Files and links", trailing: "\(artifacts.count)")
                        .selectionDisabled()
                        .listRowSeparator(.hidden)
                    ForEach(artifacts, id: \.id) { item in
                        ArtifactRow(label: item.label, detail: item.detail)
                            .selectionDisabled()
                    }
                }
            }

            Section {
                if steps.isEmpty {
                    Text("Nothing recorded for this task yet.")
                        .font(TypeScale.rowBody)
                        .foregroundStyle(.secondary)
                        .selectionDisabled()
                        .listRowSeparator(.hidden)
                } else {
                    ForEach(steps) { step in
                        SpanRow(step: step)
                            .tag(step.id)
                            .contextMenu { spanMenu(for: step) }
                    }
                }
            } header: {
                SectionHeading(
                    title: "Activity",
                    trailing: steps.isEmpty ? nil : "\(steps.count) steps"
                )
            } footer: {
                if !steps.isEmpty {
                    Text("Select a step to split it into its own task or move it elsewhere.")
                        .font(TypeScale.meta)
                        .foregroundStyle(.tertiary)
                        .padding(.top, Spacing.xs)
                }
            }
        }
        .listStyle(.inset)
        .navigationTitle(Narrative.title(for: task))
        .navigationSubtitle(Narrative.timeRange(for: task))
        .safeAreaInset(edge: .bottom, spacing: 0) { footer }
        .onAppear { titleDraft = task.title }
        .onChange(of: task.id) { _, _ in titleDraft = task.title }
        .onChange(of: task.title) { _, newValue in
            if !titleFocused { titleDraft = newValue }
        }
        .onChange(of: titleFocused) { _, focused in
            if !focused { commitTitle() }
        }
        .onChange(of: browser.renameRequestID) { _, requested in
            if requested == task.id {
                titleFocused = true
                browser.renameRequestID = nil
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
                TextField("Task title", text: $titleDraft)
                    .textFieldStyle(.plain)
                    .font(TypeScale.display)
                    .focused($titleFocused)
                    .onSubmit {
                        commitTitle()
                        titleFocused = false
                    }
                    .accessibilityLabel("Task title")

                Button {
                    browser.togglePin(taskID: task.id)
                } label: {
                    Image(systemName: task.isPinned ? Glyph.pinned : Glyph.unpinned)
                        .foregroundStyle(task.isPinned ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                }
                .buttonStyle(.accessoryBar)
                .help(task.isPinned ? "Unpin this task" : "Pin this task")
                .accessibilityLabel(task.isPinned ? "Unpin" : "Pin")
            }

            // The facts about the memory, as controls where they can be changed
            // and as chips where they cannot.
            HStack(spacing: Spacing.s) {
                if task.isOpen { LiveBadge() }
                Chip(text: Narrative.timeRange(for: task), symbol: Glyph.recent)
                ProjectChip(task: task)
                if showsDeveloperDetails {
                    Chip(text: "\(task.eventCount) observations", symbol: Glyph.evidence)
                }
            }

            if showsDeveloperDetails {
                ConfidenceIndicator(confidence: task.groupingConfidence, reasons: task.groupingReasons)
            }
        }
        .padding(.vertical, Spacing.s)
    }

    /// The two questions a person actually opens a memory to answer, in one
    /// card. "Where you left off" is omitted entirely when the recorded state
    /// is a keystroke or another fragment that would answer nothing.
    private var summaryCard: some View {
        DetailCard(title: "What you were doing", symbol: Glyph.task) {
            VStack(alignment: .leading, spacing: Spacing.m) {
                Text(showsDeveloperDetails ? task.digest : Narrative.summary(for: task))
                    .font(TypeScale.prose)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)

                if let place = Narrative.lastPlace(for: task) {
                    Divider()
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        Text("WHERE YOU LEFT OFF")
                            .font(TypeScale.section)
                            .foregroundStyle(.secondary)
                            .kerning(0.4)
                        Text(place)
                            .font(TypeScale.prose)
                            .textSelection(.enabled)
                            .help(task.lastState ?? place)
                    }
                }
            }
        }
        .padding(.vertical, Spacing.xs)
    }

    /// One clear action, and a quiet way to see the raw material behind it.
    private var footer: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: Spacing.s) {
                Button("Copy context") {
                    ContextClipboard.copy(task: task, evidence: browser.selectedTaskEvidence)
                }
                .buttonStyle(.borderedProminent)
                .help("Copy this memory as context for an agent")

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

    @ViewBuilder
    private func spanMenu(for step: ActivityStep) -> some View {
        Button("Split into a New Task") {
            ensureSelected(step)
            browser.splitSelectedSpans()
        }
        Menu("Move to") {
            ForEach(browser.displayedTasks.filter { $0.id != task.id }) { other in
                Button(Narrative.title(for: other)) {
                    ensureSelected(step)
                    browser.moveSelectedSpans(to: other.id)
                }
            }
        }
        .disabled(browser.displayedTasks.count < 2)
    }

    /// Right-clicking a step that is not part of the current selection acts on
    /// that step alone, matching Finder.
    private func ensureSelected(_ step: ActivityStep) {
        if !browser.selectedSpanIDs.contains(step.id) {
            browser.selectedSpanIDs = [step.id]
        }
    }

    private func commitTitle() {
        let trimmed = titleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            titleDraft = task.title
            return
        }
        guard trimmed != task.title else { return }
        browser.rename(trimmed, taskID: task.id)
    }
}

/// The project as an editable chip, so the one place a memory says which project
/// it belongs to is also the place you change it.
struct ProjectChip: View {
    let task: TaskMemory
    @EnvironmentObject private var browser: MemoryBrowser

    var body: some View {
        Menu {
            Button("No project") { browser.assign(taskIDs: [task.id], toWorkstream: nil) }
            Divider()
            ForEach(browser.sidebarProjects) { summary in
                Button(ProjectName.display(summary.workstream.displayName)) {
                    browser.assign(taskIDs: [task.id], toWorkstream: summary.workstream.id)
                }
            }
        } label: {
            Chip(
                text: Narrative.project(for: task) ?? "No project",
                symbol: task.workstream?.kind.glyph ?? Glyph.workstream
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Move this to another project")
    }
}

/// A file or link: the readable name, with the full path available on hover and
/// copyable on demand.
struct ArtifactRow: View {
    let label: String
    let detail: String

    var body: some View {
        HStack(spacing: Spacing.s) {
            Image(systemName: detail.hasPrefix("http") ? Glyph.browser : Glyph.document)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .frame(width: 14)
            Text(label)
                .font(TypeScale.rowBody)
                .lineLimit(1)
            Spacer(minLength: Spacing.s)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(detail, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc").font(.system(size: 10))
            }
            .buttonStyle(.accessoryBar)
            .help("Copy \(detail)")
            .accessibilityLabel("Copy path")
        }
        .padding(.vertical, 1)
        .help(detail)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(detail)
    }
}

/// Shown when nothing is selected. A multi-session selection no longer lands
/// here — it gets `TaskGroupDetailView` instead.
struct TaskDetailPlaceholder: View {
    var body: some View {
        ContentUnavailableView {
            Label("Nothing selected", systemImage: Glyph.task)
        } description: {
            Text("Choose a session to see what you were doing and where you left off.")
        }
    }
}
